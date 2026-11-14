import CoreLocation
import HoldMyTrackCore
import UIKit

/// Capture (apps/android/docs/SPEC.md FR-2.8): started from a place's popup, it reads the phone's
/// position and guides the user there, an arrow turned towards it, the distance, a dashed line on
/// the map and every place's area shaded darker, then counts 30 seconds inside (SpotCapture) and
/// captures it on the server.
///
/// Precise location is asked for first, and nothing starts without it. Location is read only
/// while the app is in the foreground, and the screen stays on meanwhile. Stop, leaving the map,
/// unticking the place's category or the capture itself ends it.
@MainActor
final class CaptureController: NSObject, @preconcurrency CLLocationManagerDelegate {
    /// What capture asks of the map.
    struct Map {
        /// The place aimed at, or none: the areas shade darker around it.
        let target: (Int?) -> Void
        /// The guide line from the user to the area's nearest point, or none.
        let guide: (GeoPoint?, GeoPoint?) -> Void
        /// Fits a `[west, south, east, north]` box.
        let frame: ([Double]) -> Void
        /// The map's own bearing, which the arrow follows without a compass.
        let bearing: () -> Double
        /// A capture saved.
        let captured: (Int, Date) -> Void
        /// Shows an explanation over the map.
        let notice: (String) -> Void
    }

    let banner = CaptureBanner()
    private let api: APIClient
    private let map: Map
    private let format: () -> PanelFormat
    private let location = CLLocationManager()

    /// The place aimed at, while capture runs.
    private(set) var spot: Spot?
    /// The place whose start waits on the location prompt.
    private var asking: Spot?
    private var capture: SpotCapture?
    private var listening = false
    private var framed = false
    private var saving = false
    private var heading: Double?
    private var bearing: Double?
    private var retry: Task<Void, Never>?
    private var foreground = true

    private static let retryAfter = Duration.seconds(5)
    /// How long "Captured!" stays before capture ends by itself.
    private static let doneFor = Duration.milliseconds(2500)
    /// How long "no longer on the map" stays: long enough to read.
    private static let goneFor = Duration.seconds(4)
    /// The Info.plist purpose key the precise location prompt explains itself with.
    private static let purposeKey = "SpotCapture"

    init(api: APIClient, map: Map, format: @escaping () -> PanelFormat) {
        self.api = api
        self.map = map
        self.format = format
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.distanceFilter = kCLDistanceFilterNone
        banner.stop.addAction(UIAction { [weak self] _ in self?.stop() }, for: .primaryActionTriggered)
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setForeground(false) }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setForeground(true) }
        }
    }

    /// Capture on target, replacing any other, once precise location is allowed.
    func start(_ target: Spot) {
        stop()
        switch (location.authorizationStatus, location.accuracyAuthorization) {
        case (.notDetermined, _):
            asking = target
            location.requestWhenInUseAuthorization()
        case (.authorizedWhenInUse, .fullAccuracy), (.authorizedAlways, .fullAccuracy):
            begin(target)
        case (.authorizedWhenInUse, _), (.authorizedAlways, _):
            location.requestTemporaryFullAccuracyAuthorization(withPurposeKey: Self.purposeKey) { [weak self] _ in
                MainActor.assumeIsolated { self?.afterPrompt(target) }
            }
        default:
            refused()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard let target = asking, manager.authorizationStatus != .notDetermined else { return }
        asking = nil
        start(target)
    }

    private func afterPrompt(_ target: Spot) {
        location.accuracyAuthorization == .fullAccuracy ? begin(target) : refused()
    }

    private func refused() {
        map.notice(String(localized: "Capture needs precise location access. Turn on Precise Location for HoldMyTrack in Settings."))
    }

    private func begin(_ target: Spot) {
        spot = target
        framed = false
        UIApplication.shared.isIdleTimerDisabled = true
        map.target(target.id)
        banner.isHidden = false
        render(nil)
        load(target)
    }

    func stop() {
        asking = nil
        guard spot != nil else { return }
        spot = nil
        capture = nil
        saving = false
        bearing = nil
        retry?.cancel()
        stopListening()
        UIApplication.shared.isIdleTimerDisabled = false
        map.target(nil)
        map.guide(nil, nil)
        banner.isHidden = true
    }

    /// The map's own bearing changed: without a compass the arrow follows it.
    func mapRotated() { renderArrow() }

    private func setForeground(_ on: Bool) {
        foreground = on
        if on, capture != nil { startListening() } else if !on { stopListening() }
    }

    private func load(_ target: Spot) {
        retry = Task {
            while !Task.isCancelled, spot?.id == target.id {
                do {
                    let area = try await api.spotArea(target.id)
                    guard spot?.id == target.id else { return }
                    capture = SpotCapture(area: area, anchor: GeoPoint(lat: target.lat, lon: target.lon))
                    render(capture?.state)
                    if foreground { startListening() }
                    return
                } catch {
                    guard spot?.id == target.id else { return }
                    if CaptureOutcome.of(error) == .gone { return gone() }
                    banner.detail.text = String(localized: "Couldn't load this place — retrying…")
                    try? await Task.sleep(for: Self.retryAfter)
                }
            }
        }
    }

    private func startListening() {
        guard !listening else { return }
        listening = true
        location.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { location.startUpdatingHeading() }
    }

    private func stopListening() {
        guard listening else { return }
        listening = false
        location.stopUpdatingLocation()
        location.stopUpdatingHeading()
        heading = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard var counting = capture, !saving else { return }
        for fix in locations {
            counting.fix(GeoPoint(lat: fix.coordinate.latitude, lon: fix.coordinate.longitude),
                         accuracyM: fix.horizontalAccuracy, timeMs: Int(fix.timestamp.timeIntervalSince1970 * 1000))
        }
        capture = counting
        let state = counting.state
        switch state {
        case let .away(_, _, from, to):
            map.guide(from, to)
            frameOnce(from, to)
        case .holding:
            map.guide(nil, nil)
        case .captured:
            map.guide(nil, nil)
            saving = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            save()
        case .locating:
            break
        }
        render(state)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else { return }
        let next = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        // Smoothed a little, taking the short way round, so the arrow doesn't jitter.
        heading = heading.map { last in last + 0.2 * ((next - last + 540).truncatingRemainder(dividingBy: 360) - 180) } ?? next
        renderArrow()
    }

    /// Once per start: the camera fits the user and the place, so the way there is on screen.
    private func frameOnce(_ from: GeoPoint, _ to: GeoPoint) {
        guard !framed, let target = spot else { return }
        framed = true
        let lats = [from.lat, to.lat, target.lat], lons = [from.lon, to.lon, target.lon]
        map.frame([lons.min()!, lats.min()!, lons.max()!, lats.max()!])
    }

    private func save() {
        guard let target = spot, case let .captured(at) = capture?.state else { return }
        retry = Task {
            while !Task.isCancelled, spot?.id == target.id {
                switch await api.captureSpot(target.id, at: at) {
                case let .saved(id, date):
                    guard spot?.id == target.id else { return }
                    map.captured(id, date)
                    banner.detail.text = target.name
                    banner.detail.isHidden = target.name == nil
                    try? await Task.sleep(for: Self.doneFor)
                    if !Task.isCancelled { stop() }
                    return
                case .outside:
                    saving = false
                    capture?.reset()
                    render(capture?.state)
                    banner.detail.text = String(localized: "Not quite inside yet — keep going")
                    return
                case .gone:
                    return gone()
                case .retry:
                    banner.detail.text = String(localized: "Couldn't save — retrying…")
                    try? await Task.sleep(for: Self.retryAfter)
                }
            }
        }
    }

    /// The place is gone from OpenStreetMap and retired (root docs/SPEC.md FR-14.1): says so,
    /// and ends capture a moment later.
    private func gone() {
        capture = nil
        stopListening()
        map.guide(nil, nil)
        banner.arrow.isHidden = true
        banner.progress.isHidden = true
        banner.title.text = String(localized: "This place is no longer on the map")
        banner.detail.isHidden = true
        retry = Task {
            try? await Task.sleep(for: Self.goneFor)
            if !Task.isCancelled { stop() }
        }
    }

    private func render(_ state: SpotCapture.State?) {
        guard let target = spot else { return }
        let name = target.name ?? SpotCategory(rawValue: target.category).map(SpotPopupView.label) ?? target.category
        banner.detail.isHidden = false
        banner.arrow.isHidden = true
        banner.progress.isHidden = true
        switch state {
        case nil, .locating:
            banner.title.text = String(localized: "Get into \(name)", comment: "Capture: the place to walk into.")
            banner.detail.text = String(localized: "Waiting for an accurate GPS fix…")
        case let .away(distance, toPlace, _, _):
            banner.title.text = String(localized: "Get into \(name)", comment: "Capture: the place to walk into.")
            banner.detail.text = String(localized: "\(self.distance(distance)) away", comment: "Capture: the distance to the place.")
            banner.arrow.isHidden = false
            bearing = toPlace
            renderArrow()
        case let .holding(held, _):
            banner.title.text = String(localized: "Stay here")
            banner.detail.text = String(localized: "Seconds left: \(SpotCapture.secondsLeft(heldMs: held))")
            banner.progress.isHidden = false
            banner.progress.setProgress(Float(held) / Float(SpotCapture.holdMs), animated: true)
        case .captured:
            banner.title.text = String(localized: "Captured!")
            banner.detail.text = String(localized: "Saving…")
            banner.progress.isHidden = false
            banner.progress.setProgress(1, animated: true)
        }
    }

    /// The arrow at the place's bearing, relative to where the phone points or, without a
    /// compass, to the map's own north.
    private func renderArrow() {
        guard let toPlace = bearing else { return }
        let facing = heading ?? map.bearing()
        banner.arrow.transform = CGAffineTransform(rotationAngle: (toPlace - facing) * .pi / 180)
    }

    private func distance(_ meters: Double) -> String {
        let format = format()
        return switch SpotCapture.short(meters, imperial: format.imperial) {
        case let .meters(n): String(localized: "\(n) m", comment: "Capture: a short distance in metres.")
        case let .feet(n): String(localized: "\(n) ft", comment: "Capture: a short distance in feet.")
        case nil: format.distance(meters)
        }
    }
}

/// Capture's banner over the map: the arrow, what to do, how far or how long, the count's
/// progress, and Stop.
final class CaptureBanner: UIView {
    let arrow = UIImageView(image: Controls.icon(UIImage(resource: .navigation), size: 24))
    let title = Controls.label("", font: Typeface.sans(DesignTokens.Text.lg, weight: DesignTokens.Weight.semibold), color: UIColor(resource: .ink))
    let detail = Controls.label("", font: Typeface.sans(DesignTokens.Text.md), color: UIColor(resource: .inkSecondary))
    let progress = UIProgressView(progressViewStyle: .default)
    let stop = Controls.secondaryButton(String(localized: "Stop"), id: "captureStop")

    init() {
        super.init(frame: .zero)
        backgroundColor = UIColor(resource: .surface)
        layer.cornerRadius = DesignTokens.Radius.lg
        layer.borderColor = UIColor(resource: .borderPanel).cgColor
        layer.borderWidth = 1
        accessibilityIdentifier = "captureBanner"
        isHidden = true
        arrow.tintColor = UIColor(resource: .accent)
        arrow.contentMode = .center
        arrow.widthAnchor.constraint(equalToConstant: 32).isActive = true
        arrow.isAccessibilityElement = false
        progress.progressTintColor = UIColor(resource: .accent)
        title.accessibilityTraits = .updatesFrequently
        detail.accessibilityTraits = .updatesFrequently
        stop.setContentHuggingPriority(.required, for: .horizontal)
        stop.setContentCompressionResistancePriority(.required, for: .horizontal)
        let texts = Controls.column([title, detail, progress], spacing: DesignTokens.Space.s4)
        let row = UIStackView(arrangedSubviews: [arrow, texts, stop])
        row.spacing = DesignTokens.Space.s12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        let m = DesignTokens.Space.s12
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: m),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -m),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -m),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}