import Foundation
import HoldMyTrackCore

/// The account's recordings on the phone and their sending (apps/ios/docs/SPEC.md FR-5.2): what the
/// Sync tab lists, each sent on its own under `recorded` without a tick (RecordingSends), on Save,
/// on every return to the app and on Retry. Each one the server took is asked about every 2
/// seconds, on any tab, until it lands, when it leaves the phone, or its ingest fails, when it's
/// listed again. The tab bar owns it, so the follow-up outlives the tab. The rows swiped aside are
/// kept beside the recordings (RecordingStore.hidden).
@MainActor
final class RecordingsSync {
    private let api: APIClient
    private let account: String
    private let emailVerified: Bool
    let isDemo: Bool
    private let store: RecordingStore
    private var polling: Task<Void, Never>?
    /// Counts follow-ups, so one cancelled and replaced doesn't clear its replacement.
    private var pollGeneration = 0
    /// The signed-in screen went: nothing more is sent, written or asked.
    private var stopped = false
    /// The recordings the running send is sending; empty between sends.
    private(set) var inFlight: Set<String> = []
    private(set) var sending = false
    /// A send asked for while one ran, which picked its recordings already: it runs after.
    private var sendAgain = false
    /// The recordings a screen is open about (Hold), by hold.
    private var holds: [UUID: String] = [:]
    /// What the server refused, or failed to add, since launch: sent again only on Retry.
    private var refused: [String: RecordingSync.Refusal] = [:]
    /// The recordings whose last request failed, the latest last: last in the next send.
    private var setBack: [String] = []
    /// The recording whose request is out now.
    private var asking: String?
    /// The recordings seen to land, for a Delete asked about before (RecordingSends.deletion).
    private var landedIDs: Set<String> = []
    /// Sent recordings whose ingest failed since the tab last asked (takeFailed).
    private var failed: [RecordedTrack] = []

    static let changed = Notification.Name("RecordingsSync.changed")
    /// A recording landed: the map reads its list and tiles again.
    var onLanded: (() -> Void)?
    /// A recording's ingest failed and it's listed again.
    var onFailed: (() -> Void)?

    init(api: APIClient, account: String, emailVerified: Bool, isDemo: Bool, store: RecordingStore = RecordingController.defaultStore) {
        self.api = api
        self.account = account
        self.emailVerified = emailVerified
        self.isDemo = isDemo
        self.store = store
        follow()
    }

    var all: [RecordedTrack] { store.list(account: account) }
    private var awaited: Int { all.filter(\.sent).count }

    /// What track's row says.
    func note(_ track: RecordedTrack) -> RecordingSends.Note? {
        RecordingSends.note(sent: track.sent, sending: isSending(track.id), hidden: hidden.contains(track.id), refusal: refused[track.id], isDemo: isDemo)
    }

    /// Keeps a recording out of any send while a screen about it is open, so it isn't sent before
    /// it's named, discarded or deleted. Released when the screen closes, or with whatever holds it.
    final class Hold {
        private let onRelease: @MainActor @Sendable () -> Void

        fileprivate init(onRelease: @escaping @MainActor @Sendable () -> Void) { self.onRelease = onRelease }

        @MainActor func release() { onRelease() }

        deinit {
            let onRelease = onRelease
            Task { @MainActor in onRelease() }
        }
    }

    func hold(_ id: String) -> Hold {
        let key = UUID()
        holds[key] = id
        // Picked by a running send and not asked yet: left out of it.
        if asking != id, inFlight.remove(id) != nil { changed() }
        return Hold { [weak self] in
            guard let self, self.holds.removeValue(forKey: key) != nil else { return }
            // What's kept goes now.
            self.send()
        }
    }

    /// The rows swiped aside, kept in the account's recordings folder (RecordingStore.hidden).
    var hidden: Set<String> {
        get { store.hidden(account: account) }
        set {
            store.setHidden(newValue, account: account)
            changed()
        }
    }

    /// The sent recordings whose ingest failed since last asked.
    func takeFailed() -> [RecordedTrack] {
        defer { failed = [] }
        return failed
    }

    /// Edit's name, description and type, written onto the stored recording as it is now: one
    /// that landed meanwhile isn't written back, and one sent meanwhile stays sent.
    func update(_ track: RecordedTrack) {
        guard !stopped, var current = all.first(where: { $0.id == track.id }) else { return }
        current.name = track.name
        current.description = track.description
        current.type = track.type
        try? store.save(current, account: account)
        changed()
    }

    /// The recorder wrote a recording to the phone itself (a Stop, or an unfinished one saved):
    /// what lists or counts the recordings reads them again.
    func recorded() {
        guard !stopped else { return }
        changed()
    }

    /// Whether id is being sent now: Edit and Delete wait for the send.
    func isSending(_ id: String) -> Bool { inFlight.contains(id) }

    func delete(_ id: String) -> RecordingSends.Deletion {
        let stored = all.first { $0.id == id }
        let deletion = RecordingSends.deletion(stored: stored != nil, going: isSending(id) || stored?.sent == true, landed: landedIDs.contains(id))
        guard deletion == .deleted else { return deletion }
        store.delete(id: id, account: account)
        refused[id] = nil
        changed()
        return .deleted
    }

    /// Sends what's waiting, one recording at a time; retry sends what the server refused too. A
    /// request that fails decides nothing unless the server refused its recording with it.
    func send(retry: Bool = false) {
        guard !stopped, RecordingSends.sends(emailVerified: emailVerified, isDemo: isDemo) else { return }
        guard !sending else {
            sendAgain = true
            return
        }
        let batch = RecordingSends.toSend(all, hidden: hidden, held: Set(holds.values), refused: Set(refused.keys), setBack: setBack, retry: retry)
        guard !batch.isEmpty else { return }
        sending = true
        inFlight = Set(batch.map(\.id))
        changed()
        Task {
            await run(batch)
            inFlight = []
            sending = false
            guard !stopped else { return }
            changed()
            follow()
            if sendAgain {
                sendAgain = false
                send()
            }
        }
    }

    private func run(_ batch: [RecordedTrack]) async {
        var afterUnanswered = false
        for track in batch {
            // Left out since the batch was picked, by a hold or an Undo that hid it again.
            guard inFlight.contains(track.id) else { continue }
            defer {
                inFlight.remove(track.id)
                changed()
                follow()
            }
            if hidden.contains(track.id) { continue }
            if let refusal = RecordingSync.refusal(track) {
                refused[track.id] = refusal
                continue
            }
            asking = track.id
            defer { asking = nil }
            do {
                let refusal = try await ask(track)
                // Signed out meanwhile: the account's folder may be gone, and stays gone.
                if stopped { return }
                refused[track.id] = refusal
                setBack.removeAll { $0 == track.id }
                afterUnanswered = false
                // The stored copy as it is now, so nothing written meanwhile is lost.
                if refusal == nil, var sent = all.first(where: { $0.id == track.id }) {
                    sent.sent = true
                    try? store.save(sent, account: account)
                }
            } catch {
                if stopped { return }
                let error = (error as? APIError) ?? .unreachable
                let failure = RecordingSends.failure(error, afterUnanswered: afterUnanswered)
                afterUnanswered = RecordingSends.unanswered(error)
                setBack.removeAll { $0 == track.id }
                switch failure {
                case .stop:
                    setBack.append(track.id)
                    return
                case .next: setBack.append(track.id)
                case .refuse(let refusal): refused[track.id] = refusal
                }
            }
        }
    }

    /// The UI tests' -hmtSendsFail fails every send, as with no connection.
    private func ask(_ track: RecordedTrack) async throws -> RecordingSync.Refusal? {
        if ProcessInfo.processInfo.arguments.contains("-hmtSendsFail") { throw APIError.unreachable }
        return try await api.sendRecording(track)
    }

    /// Asks after every recording sent and awaited until none is left.
    func follow() {
        guard polling == nil, !stopped, !isDemo, awaited > 0 else { return }
        pollGeneration += 1
        let generation = pollGeneration
        polling = Task { [weak self] in
            while let self, !Task.isCancelled, !self.stopped {
                let waiting = self.all.filter(\.sent)
                if waiting.isEmpty { break }
                if let answer = try? await self.api.knownRecordings(waiting.map(\.id)) {
                    self.settle(waiting, known: answer.known, processing: answer.processing)
                }
                try? await Task.sleep(for: .seconds(RecordingSync.poll))
            }
            if let self, self.pollGeneration == generation { self.polling = nil }
        }
    }

    private func settle(_ waiting: [RecordedTrack], known: Set<String>, processing: Set<String>) {
        guard !stopped else { return }
        var landed = false, failed = false
        for track in waiting {
            switch RecordingSync.outcome(track.id, known: known, processing: processing) {
            case nil: continue
            case .landed:
                store.delete(id: track.id, account: account)
                landedIDs.insert(track.id)
                landed = true
            case .failed:
                var back = track
                back.sent = false
                try? store.save(back, account: account)
                // Not sent again by itself: the same recording would likely fail the same way.
                refused[track.id] = .ingestFailed
                self.failed.append(back)
                failed = true
            }
        }
        if landed || failed { changed() }
        if landed { onLanded?() }
        if failed { onFailed?() }
    }

    /// The signed-in screen is going: nothing more is asked.
    func stop() {
        stopped = true
        polling?.cancel()
        polling = nil
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    /// The type the account's next recording gets, kept in its recordings folder (RecordingStore),
    /// so it goes with a deleted account and stays out of backups.
    func setDefaultType(_ type: String) {
        store.setDefaultType(type, account: account)
    }
}