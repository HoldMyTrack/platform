import Foundation
import HoldMyTrackCore

/// The account's recordings on the phone and their sending (apps/ios/docs/SPEC.md FR-5.2): what the
/// Sync tab lists, the ticked ones sent one at a time under `recorded`, and each one the server
/// took asked about every 2 seconds, on any tab, until it lands, when it leaves the phone, or its
/// ingest fails, when it's listed again. The tab bar owns it, so the follow-up outlives the tab.
/// The rows swiped aside are kept here too, per account (SyncHidden).
@MainActor
final class RecordingsSync {
    private let api: APIClient
    private let account: String
    let isDemo: Bool
    private let store: RecordingStore
    private var polling: Task<Void, Never>?
    /// Counts follow-ups, so one cancelled and replaced doesn't clear its replacement.
    private var pollGeneration = 0
    /// The signed-in screen went: nothing more is sent, written or asked.
    private var stopped = false
    private(set) var sending = false
    /// The rows ticked to send; nothing starts ticked.
    var ticked: Set<String> = []
    /// What the last send did, said over the list until the next one.
    private(set) var report: Report?
    /// Sent recordings whose ingest failed since the tab last asked (takeFailed).
    private var failed: [RecordedTrack] = []

    /// What a send did: how many the server took, each refused with why (they stay ticked), and
    /// why it stopped early, if it did.
    struct Report {
        var sent = 0
        var refused: [(track: RecordedTrack, refusal: RecordingSync.Refusal)] = []
        var stopped: APIError?
    }

    static let changed = Notification.Name("RecordingsSync.changed")
    /// A recording landed: the map reads its list and tiles again.
    var onLanded: (() -> Void)?
    /// A recording's ingest failed and it's listed again.
    var onFailed: (() -> Void)?

    init(api: APIClient, account: String, isDemo: Bool, store: RecordingStore = RecordingController.defaultStore) {
        self.api = api
        self.account = account
        self.isDemo = isDemo
        self.store = store
        follow()
    }

    var all: [RecordedTrack] { store.list(account: account) }
    var awaited: Int { all.filter(\.sent).count }

    /// The rows swiped aside, kept on the phone for this account; one that left the phone is
    /// forgotten as it's read.
    var hidden: Set<String> {
        get {
            let kept = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenKey(account)) ?? [])
            let present = SyncHidden.pruned(kept, present: all)
            if present != kept { UserDefaults.standard.set(Array(present), forKey: Self.hiddenKey(account)) }
            return present
        }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.hiddenKey(account)) }
    }

    private static func hiddenKey(_ account: String) -> String { "sync.hidden.\(account)" }

    /// A deleted account's hidden rows go with it.
    static func forget(account: String) { UserDefaults.standard.removeObject(forKey: hiddenKey(account)) }

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

    /// Whether id is being sent now: Edit and Delete wait for the send.
    func isSending(_ id: String) -> Bool { sending && ticked.contains(id) }

    func delete(_ id: String) {
        guard !isSending(id) else { return }
        store.delete(id: id, account: account)
        ticked.remove(id)
        changed()
    }

    /// tracks, the rows ticked and shown, one recording at a time; a run cut short leaves the rest
    /// ticked.
    func send(_ tracks: [RecordedTrack]) async {
        guard !sending, !stopped, !isDemo, !tracks.isEmpty else { return }
        sending = true
        report = Report()
        changed()
        for track in tracks {
            if stopped { break }
            if let refusal = RecordingSync.refusal(track) {
                report?.refused.append((track, refusal))
                continue
            }
            do {
                let refusal = try await api.sendRecording(track)
                // Signed out meanwhile: the account's folder may be gone, and stays gone.
                if stopped { break }
                if let refusal {
                    report?.refused.append((track, refusal))
                } else {
                    // The stored copy as it is now, so nothing written meanwhile is lost.
                    if var sent = all.first(where: { $0.id == track.id }) {
                        sent.sent = true
                        try? store.save(sent, account: account)
                    }
                    ticked.remove(track.id)
                    report?.sent += 1
                }
            } catch {
                // Unreachable or refused as a whole: what wasn't confirmed stays ticked.
                report?.stopped = (error as? APIError) ?? .unreachable
                break
            }
            changed()
        }
        sending = false
        changed()
        follow()
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
                landed = true
            case .failed:
                var back = track
                back.sent = false
                try? store.save(back, account: account)
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