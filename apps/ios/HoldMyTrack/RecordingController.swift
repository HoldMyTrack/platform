import CoreLocation
import HoldMyTrackCore
import OSLog
import UIKit

/// GPS recording (apps/ios/docs/SPEC.md FR-5.1, IMPLEMENTATION.md §5): the record button's taps
/// and hold, location while in use with the background indicator, the recording as values
/// (Recording), and Stop's save to the phone under the account (RecordingStore). The tab bar owns
/// it, since the button is on every tab; the map draws what it reports.
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

    static let purposeKey = "Recording"
    private static let log = Logger(subsystem: "dev.holdmytrack.ios", category: "recording")

    init(account: String, store: RecordingStore = RecordingController.defaultStore) {
        self.account = account
        self.store = store
        super.init()
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
                    if self.access == .precise { self.start() } else { self.onMessage?(Self.needsLocation) }
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
        guard let finished else { return nil }
        do {
            try store.save(finished, account: account)
            return true
        } catch {
            return false
        }
    }

    private func start() {
        recording.start(at: Date())
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
        locate(false)
        changed()
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
            if recording.add(point, accuracy: fix.horizontalAccuracy) { kept = true }
        }
        if kept { changed() }
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
