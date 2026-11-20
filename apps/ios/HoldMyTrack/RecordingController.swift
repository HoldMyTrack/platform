import CoreLocation
import HoldMyTrackCore
import OSLog
import UIKit
import UserNotifications

/// GPS recording (apps/ios/docs/SPEC.md FR-5.1, IMPLEMENTATION.md §5): the record button's taps
/// and hold, location while in use with the background indicator, the recording as values
/// (Recording), every fix written to the journal as it's kept (RecordingJournal), and Stop's save
/// to the phone under the account (RecordingStore). What a crash or a swipe left is offered back
/// when the signed-in screen opens (LeftoverAction). The tab bar owns it, since the button is on
/// every tab; the map draws what it reports.
@MainActor
final class RecordingController: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let location = CLLocationManager()
    private let account: String
    private let store: RecordingStore
    private(set) var recording = Recording()
    /// A tap that asked for access, made once iOS answers.
    private var startWhenAllowed = false
    private var ticker: Timer?

    /// The recording changed: its state or a fix kept.
    var onChange: (() -> Void)?
    /// A second of the recording's clock: only the status line changes.
    var onTick: (() -> Void)?
    /// Something to say over the map: saved, too short, or how swiping away ends a recording.
    var onMessage: ((String) -> Void)?
    /// Location is off for the app; the owner offers Settings.
    var onRefused: (() -> Void)?
    /// A recording the app died in, to ask about: Resume, Save or Discard.
    var onLeftover: ((RecordingJournal.Leftover) -> Void)?
    private let journal: RecordingJournal?

    static let purposeKey = "Recording"
    private static let log = Logger(subsystem: "dev.holdmytrack.ios", category: "recording")

    init(account: String, store: RecordingStore = RecordingController.defaultStore, journal: RecordingJournal? = RecordingController.defaultJournal) {
        self.account = account
        self.store = store
        self.journal = journal
        super.init()
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appWillTerminate() }
        }
        location.delegate = self
        location.activityType = .fitness
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.distanceFilter = kCLDistanceFilterNone
        location.pausesLocationUpdatesAutomatically = false
    }

    deinit {
        MainActor.assumeIsolated { ticker?.invalidate() }
    }

    static let defaultStore = RecordingStore(root: URL.applicationSupportDirectory.appending(path: "Recordings", directoryHint: .isDirectory))
    /// One journal for the phone: a leftover keeps its account in it.
    static let defaultJournal = try? RecordingJournal(path: URL.applicationSupportDirectory.appending(path: "Recordings/live.sqlite"))

    var state: RecordingState { recording.state }

    private var access: RecordingAccess {
        switch location.authorizationStatus {
        case .notDetermined: .notAsked
        case .denied, .restricted: .denied
        default: location.accuracyAuthorization == .fullAccuracy ? .precise : .approximate
        }
    }

    // MARK: The button

    func tap() {
        switch RecordTap.of(recording.state, access: access) {
        case .start: start()
        case .pause: pause()
        case .resume:
            recording.resume(at: Date())
            locate(true)
            changed()
        case .askLocation:
            startWhenAllowed = true
            location.requestWhenInUseAuthorization()
        case .askPrecise:
            location.requestTemporaryFullAccuracyAuthorization(withPurposeKey: Self.purposeKey) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.access == .precise { self.tap() } else { self.onMessage?(Self.needsLocation) }
                }
            }
        case .refused: onRefused?()
        }
    }

    /// The two-second hold: the recording saved if it's long enough, else dropped, and said so.
    func stop() {
        guard recording.state != .idle else { return }
        guard let outcome = end(save: true) else {
            onMessage?(String(localized: "recording.tooShort", defaultValue: "Too short — not saved.", comment: "Recording: Stop on less than a minute or two points."))
            return
        }
        onMessage?(outcome
            ? String(localized: "recording.saved", defaultValue: "Recording saved on this phone.", comment: "Recording: Stop kept it on the phone.")
            : String(localized: "recording.saveFailed", defaultValue: "The recording couldn't be saved.", comment: "Recording: Stop failed to write it."))
    }

    /// Ends the recording, saved as Stop saves it or, for a deleted account, dropped: nil when
    /// there was nothing long enough to keep, else whether the save worked. The signed-in screen
    /// calls it as it goes, so a sign-out keeps what a Stop would.
    @discardableResult
    func end(save: Bool) -> Bool? {
        guard recording.state != .idle else { return nil }
        let now = Date()
        let finished = save ? recording.finished(at: now, type: "unknown") : nil
        Self.log.info("end: \(self.recording.points.count) points, \(Int(self.recording.moving(at: now))) s moving, kept: \(finished != nil)")
        locate(false)
        ticker?.invalidate()
        ticker = nil
        recording = Recording()
        changed()
        guard let finished else {
            try? journal?.clear()
            return nil
        }
        do {
            try store.save(finished, account: account)
            // Only once it's in the store: a save that failed leaves it to be offered again.
            try? journal?.clear()
            return true
        } catch {
            return false
        }
    }

    private func start() {
        // Another account's leftover waits for it; a new recording saves it under that account first.
        if let left = journal?.leftover(), left.account != account { save(left) }
        recording.start(at: Date())
        do {
            try journal?.begin(id: recording.id, account: account, startedAt: recording.startedAt ?? Date())
        } catch {
            Self.log.error("journal: \(String(describing: error), privacy: .public)")
        }
        askNotifications()
        locate(true)
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTick?() }
        }
        changed()
        if !UserDefaults.standard.bool(forKey: Self.swipeNoticeKey) {
            UserDefaults.standard.set(true, forKey: Self.swipeNoticeKey)
            onMessage?(String(localized: "recording.swipeEnds", defaultValue: "Recording. Swiping HoldMyTrack away in the app switcher stops it.", comment: "Recording: said once, at the first recording on the phone."))
        }
    }

    private func pause() {
        recording.pause(at: Date())
        writeTotals()
        locate(false)
        changed()
    }

    private func writeTotals() {
        try? journal?.totals(id: recording.id, moving: recording.moving(at: Date()), meters: recording.meters)
    }

    /// Location on while recording and off while paused, so a pause leaves the GPS and the
    /// indicator off. Background updates are allowed before updates start, and only then: set any
    /// other time, the indicator shows with nothing recording.
    private func locate(_ on: Bool) {
        if on {
            location.allowsBackgroundLocationUpdates = true
            location.showsBackgroundLocationIndicator = true
            location.startUpdatingLocation()
        } else {
            location.stopUpdatingLocation()
            location.allowsBackgroundLocationUpdates = false
        }
    }

    private static let swipeNoticeKey = "recording.swipeNoticeShown"

    static var needsLocation: String {
        String(localized: "recording.needsLocation", defaultValue: "HoldMyTrack needs location access to record a GPS track.", comment: "Recording: location or precise location refused.")
    }

    private func changed() { onChange?() }

    // MARK: Location

    /// iOS calls this when the delegate is set and on every change: a recording pauses when
    /// location or precise location is taken away, keeping what it has, since every fix would be
    /// dropped while its clock ran; and a tap that asked goes on once answered.
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if access != .precise, recording.state == .recording { pause() }
        guard startWhenAllowed, access != .notAsked else { return }
        startWhenAllowed = false
        if access == .denied { onMessage?(Self.needsLocation) } else { tap() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        var kept = false
        for fix in locations {
            let point = RecordedPoint(lat: fix.coordinate.latitude, lon: fix.coordinate.longitude,
                                      ele: fix.verticalAccuracy >= 0 ? fix.altitude : nil, time: fix.timestamp)
            guard recording.add(point, accuracy: fix.horizontalAccuracy) else { continue }
            kept = true
            try? journal?.append(point, id: recording.id, moving: recording.moving(at: point.time), meters: recording.meters)
        }
        if kept { changed() }
    }

    // MARK: A leftover

    /// The signed-in screen opened, or the notification's tap brought the app back: a leftover
    /// under this account is resumed for that tap and asked about otherwise.
    func checkLeftover(resumeAsked: Bool) {
        let left = journal?.leftover()
        Self.log.info("leftover: \(left?.points.count ?? -1) points for \(left?.account == self.account ? "this" : "another", privacy: .public) account, journal \(self.journal == nil ? "missing" : "open", privacy: .public)")
        switch LeftoverAction.of(leftover: left?.account, signedIn: account, recording: recording.state, resumeAsked: resumeAsked) {
        case .none, .wait: return
        case .resume: if let left { resume(left) }
        case .prompt: if let left { onLeftover?(left) }
        }
    }

    /// Picked up paused where it was, then resumed as a tap would, asking for precise location
    /// first if it's gone; refused, it stays paused.
    func resume(_ left: RecordingJournal.Leftover) {
        recording = Recording.restored(left)
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTick?() }
        }
        changed()
        tap()
    }

    /// Kept as Stop keeps it, under its own account.
    @discardableResult
    func save(_ left: RecordingJournal.Leftover) -> Bool {
        let restored = Recording.restored(left)
        guard let track = restored.finished(at: left.points.last?.time ?? Date(), type: "unknown") else {
            try? journal?.clear()
            return false
        }
        do {
            try store.save(track, account: left.account)
            try? journal?.clear()
            return true
        } catch {
            return false
        }
    }

    func discard() {
        try? journal?.clear()
    }

    // MARK: The app going away

    /// The app is being closed, by a swipe in the app switcher while it records: the totals as of
    /// now, and a notification whose tap brings the recording back. iOS ends location with the
    /// app, so the time until then counts as a pause.
    private func appWillTerminate() {
        guard recording.state != .idle else { return }
        writeTotals()
        guard recording.state == .recording else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "recording.closedTitle", defaultValue: "Recording paused: HoldMyTrack was closed", comment: "The notification posted as the app is swiped away while recording.")
        content.body = String(localized: "recording.closedBody", defaultValue: "Tap to go on recording.", comment: "The notification posted as the app is swiped away while recording: its tap resumes.")
        let request = UNNotificationRequest(identifier: Self.closedNotification, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        // The app ends once this returns: the request has to be in before then.
        let added = DispatchSemaphore(value: 0)
        UNUserNotificationCenter.current().add(request) { _ in added.signal() }
        _ = added.wait(timeout: .now() + 2)
    }

    nonisolated static let closedNotification = "recording-closed"

    /// Asked once, at the first recording: the swipe's notification needs it, recording doesn't.
    private func askNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: The status line

    /// The line over the button (RecordingStatus), in words.
    func status(format: PanelFormat, holding: Bool, at now: Date) -> String? {
        switch RecordingStatus.of(recording, holding: holding, at: now) {
        case .none: return nil
        case .holding:
            return String(localized: "recording.holding", defaultValue: "Keep holding to stop…", comment: "Recording: the hold that stops is under way.")
        case .waiting:
            return String(localized: "recording.waiting", defaultValue: "Waiting for GPS…", comment: "Recording: no precise fix yet.")
        case .paused(let moving):
            return String(localized: "recording.paused", defaultValue: "Paused · \(RecordingStatus.clock(moving))", comment: "Recording: paused, and its moving time.")
        case .running(let moving, let meters):
            return "\(RecordingStatus.clock(moving)) · \(format.distance(meters))"
        }
    }
}
