import Foundation
import HoldMyTrackCore

/// The account's recordings on the phone and their sending (apps/ios/docs/SPEC.md FR-5.2): what the
/// Sync tab lists, the ticked ones sent one at a time under `recorded`, and each one the server
/// took asked about every 2 seconds, on any tab, until it lands, when it leaves the phone, or its
/// ingest fails, when it's listed again. The tab bar owns it, so the follow-up outlives the tab.
@MainActor
final class RecordingsSync {
    private let api: APIClient
    private let account: String
    let isDemo: Bool
    private let store: RecordingStore
    private var polling: Task<Void, Never>?
    private(set) var sending = false
    /// The rows ticked to send; nothing starts ticked.
    var ticked: Set<String> = []
    /// Why each refused recording wasn't taken, shown on its row, which stays ticked.
    private(set) var refusals: [String: RecordingSync.Refusal] = [:]

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
    var listed: [RecordedTrack] { RecordingSync.listed(all) }
    var awaited: Int { all.filter(\.sent).count }

    func update(_ track: RecordedTrack) {
        try? store.save(track, account: account)
        changed()
    }

    func delete(_ id: String) {
        store.delete(id: id, account: account)
        ticked.remove(id)
        refusals[id] = nil
        changed()
    }

    /// The ticked rows, one recording at a time; a run cut short leaves the rest ticked.
    func send() async {
        guard !sending, RecordingSync.canSend(ticked: ticked, isDemo: isDemo) else { return }
        sending = true
        changed()
        for track in listed where ticked.contains(track.id) {
            if let refusal = RecordingSync.refusal(track) {
                refusals[track.id] = refusal
                continue
            }
            do {
                if let refusal = try await api.sendRecording(track) {
                    refusals[track.id] = refusal
                } else {
                    var sent = track
                    sent.sent = true
                    try? store.save(sent, account: account)
                    ticked.remove(track.id)
                    refusals[track.id] = nil
                }
            } catch {
                // Unreachable or refused as a whole: what wasn't confirmed stays ticked.
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
        guard polling == nil, !isDemo, awaited > 0 else { return }
        polling = Task { [weak self] in
            while let self, !Task.isCancelled {
                let waiting = self.all.filter(\.sent)
                if waiting.isEmpty { break }
                if let answer = try? await self.api.knownRecordings(waiting.map(\.id)) {
                    self.settle(waiting, known: answer.known, processing: answer.processing)
                }
                try? await Task.sleep(for: .seconds(RecordingSync.poll))
            }
            self?.polling = nil
        }
    }

    private func settle(_ waiting: [RecordedTrack], known: Set<String>, processing: Set<String>) {
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
                failed = true
            }
        }
        if landed || failed { changed() }
        if landed { onLanded?() }
        if failed { onFailed?() }
    }

    /// The signed-in screen is going: nothing more is asked.
    func stop() {
        polling?.cancel()
        polling = nil
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    /// The type a new recording gets: the last one set in Edit on this account, `unknown` at first.
    static func defaultType(account: String) -> String {
        UserDefaults.standard.string(forKey: "recording.type.\(account)") ?? "unknown"
    }

    static func setDefaultType(_ type: String, account: String) {
        UserDefaults.standard.set(type, forKey: "recording.type.\(account)")
    }
}