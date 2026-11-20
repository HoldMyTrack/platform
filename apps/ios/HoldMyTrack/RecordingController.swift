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

    /// The recording changed: its state, a fix, or a second of its clock.
    var onChange: (() -> Void)?
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
        case .pause:
            recording.pause(at: Date())
            changed()
        case .resume:
            recording.resume(at: Date())
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

    /// The two-second hold: the recording saved if it's long enough, else dropped.
    func stop() {
        guard recording.state != .idle else { return }
        let now = Date()
        let finished = recording.finished(at: now, type: "unknown")
        Self.log.info("stop: \(self.recording.points.count) points, \(Int(self.recording.moving(at: now))) s moving, kept: \(finished != nil)")
        location.stopUpdatingLocation()
        location.allowsBackgroundLocationUpdates = false
        ticker?.invalidate()
        ticker = nil
        recording = Recording()
        changed()
        guard let finished else {
            onMessage?(String(localized: "recording.tooShort", defaultValue: "Too short — not saved.", comment: "Recording: Stop on less than a minute or two points."))
            return
        }
        do {
            try store.save(finished, account: account)
            onMessage?(String(localized: "recording.saved", defaultValue: "Recording saved on this phone.", comment: "Recording: Stop kept it on the phone."))
        } catch {
            onMessage?(String(localized: "recording.saveFailed", defaultValue: "The recording couldn't be saved.", comment: "Recording: Stop failed to write it."))
        }
    }

    private func start() {
        recording.start(at: Date())
        // Set before updates start: with the location background mode, updates go on with the
        // screen off and the app in the background, under iOS's location indicator.
        location.allowsBackgroundLocationUpdates = true
        location.showsBackgroundLocationIndicator = true
        location.startUpdatingLocation()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
        changed()
        if !UserDefaults.standard.bool(forKey: Self.swipeNoticeKey) {
            UserDefaults.standard.set(true, forKey: Self.swipeNoticeKey)
            onMessage?(String(localized: "recording.swipeEnds", defaultValue: "Recording. Swiping HoldMyTrack away in the app switcher stops it.", comment: "Recording: said once, at the first recording on the phone."))
        }
    }

    private static let swipeNoticeKey = "recording.swipeNoticeShown"

    static var needsLocation: String {
        String(localized: "recording.needsLocation", defaultValue: "HoldMyTrack needs location access to record a GPS track.", comment: "Recording: location or precise location refused.")
    }

    private func changed() { onChange?() }

    // MARK: Location

    /// iOS calls this when the delegate is set and on every change: a recording pauses when
    /// location is taken away, keeping what it has, and a tap that asked goes on once answered.
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if access == .denied, recording.state == .recording {
            recording.pause(at: Date())
            changed()
        }
        guard startWhenAllowed, access != .notAsked else { return }
        startWhenAllowed = false
        if access == .denied { onMessage?(Self.needsLocation) } else { tap() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        var kept = false
        Self.log.debug("fixes: \(locations.count), accuracy \(locations.last?.horizontalAccuracy ?? -1)")
        for fix in locations {
            let point = RecordedPoint(lat: fix.coordinate.latitude, lon: fix.coordinate.longitude,
                                      ele: fix.verticalAccuracy >= 0 ? fix.altitude : nil, time: fix.timestamp)
            if recording.add(point, accuracy: fix.horizontalAccuracy) { kept = true }
        }
        if kept { changed() }
    }

    // MARK: The status line

    /// The line over the button: the clock and distance, waiting for the first fix, or paused.
    func status(format: PanelFormat, holding: Bool) -> String? {
        let now = Date()
        switch recording.state {
        case .idle: return nil
        case _ where holding:
            return String(localized: "recording.holding", defaultValue: "Keep holding to stop…", comment: "Recording: the hold that stops is under way.")
        case .paused:
            return String(localized: "recording.paused", defaultValue: "Paused · \(Self.clock(recording.moving(at: now)))", comment: "Recording: paused, and its moving time.")
        case .recording:
            guard !recording.points.isEmpty else {
                return String(localized: "recording.waiting", defaultValue: "Waiting for GPS…", comment: "Recording: no precise fix yet.")
            }
            return "\(Self.clock(recording.moving(at: now))) · \(format.distance(recording.meters))"
        }
    }

    /// H:MM:SS, as Android's.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
    }
}