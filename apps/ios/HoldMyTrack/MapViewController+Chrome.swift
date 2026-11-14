import HoldMyTrackCore
import MapLibre
import UIKit

/// What the map shows beside the modes (apps/android/docs/SPEC.md FR-2.2): the chip naming what
/// Fog covers, the Layers button's badge, and whether Satellite imagery loads on this device (root docs/SPEC.md FR-4.10). The decisions are
/// HoldMyTrackCore's MapChrome and SatelliteStatus.
extension MapViewController {
    /// The chip and Fog's level for the mode shown.
    func renderModeChrome() {
        let chip = MapChrome.chip(state.mode)
        chrome.chip.text = switch chip {
        case .everyActivity: String(localized: "Every activity, any date")
        case nil: nil
        }
        chrome.chip.isHidden = chip == nil
        renderLevel()
    }

    /// The Layers button filled while picks show, with their count on its corner, greyed while
    /// Show layers hides them.
    func renderLayersButton(_ button: UIButton) {
        let badge = MapChrome.layersBadge(state, places: spots.categories.count)
        button.configuration?.baseBackgroundColor = UIColor(resource: badge.filled ? .ink : .surface)
        button.configuration?.baseForegroundColor = UIColor(resource: badge.filled ? .surface : .ink)
        chrome.badge.text = " \(badge.count) "
        chrome.badge.isHidden = badge.count == 0
        chrome.badge.alpha = badge.greyed ? 0.55 : 1
        let label = String(localized: "Layers")
        button.accessibilityLabel = badge.count > 0 ? "\(label), \(badge.count)" : label
    }

    /// The imagery's status changed: the look follows, the layer stays as switched.
    func onImagery(_ status: SatelliteStatus) {
        state.satelliteFailed = status == .failed
        render()
        renderImageryNotice()
    }

    func renderImageryNotice() {
        if state.satellite && state.satelliteFailed {
            notice(.satellite, String(localized: "Satellite imagery couldn't load."))
        } else {
            hideNotice(.satellite)
        }
    }

    /// Satellite's wait counts while the map is on screen with Satellite switched on.
    func countSatelliteWait(onScreen: Bool) {
        let available = pair.map { MapStyle.hasSatellite($0.style) } ?? false
        chrome.satellite.count(onScreen && available && state.satellite)
        renderImageryNotice()
    }
}

/// The views MapViewController+Chrome renders, and Satellite's watch.
@MainActor
final class MapChromeViews {
    let chip = InsetLabel(insets: UIEdgeInsets(top: 0, left: DesignTokens.Space.s16, bottom: 0, right: DesignTokens.Space.s16))
    let badge = UILabel()
    let satellite: SatelliteWatch

    init(onImagery: @escaping (SatelliteStatus) -> Void) {
        satellite = SatelliteWatch(onChange: onImagery)
        chip.font = Typeface.sans(DesignTokens.Text.lg)
        chip.adjustsFontForContentSizeCategory = true
        chip.textColor = UIColor(resource: .ink)
        chip.numberOfLines = 0
        chip.textAlignment = .center
        chip.layer.masksToBounds = true
        chip.isHidden = true
        chip.backgroundColor = UIColor(resource: .surface)
        chip.layer.cornerRadius = 20
        chip.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        chip.accessibilityIdentifier = "modeChip"
        badge.font = Typeface.sans(DesignTokens.Text.xxxs, weight: DesignTokens.Weight.bold)
        badge.textColor = UIColor(resource: .onAccent)
        badge.backgroundColor = UIColor(resource: .accent)
        badge.textAlignment = .center
        badge.layer.cornerRadius = 8
        badge.layer.masksToBounds = true
        badge.isAccessibilityElement = false
        badge.isHidden = true
    }
}

/// Times the first imagery tile while it's counting (Satellite on, the map on screen) and hands
/// onChange each new SatelliteStatus; the basemap's clock in MapViewController.
@MainActor
final class SatelliteWatch {
    private var loaded = false
    private var failed = false
    private var waitedMs = 0
    /// Since when the wait has counted, nil while it's paused.
    private var since: Date?
    private var status = SatelliteStatus.loading
    private var tick: Task<Void, Never>?
    private let onChange: (SatelliteStatus) -> Void

    init(onChange: @escaping (SatelliteStatus) -> Void) {
        self.onChange = onChange
    }

    /// Starts or pauses the wait.
    func count(_ on: Bool) {
        report(counting: on)
    }

    func tile(loaded tileLoaded: Bool) {
        if tileLoaded { loaded = true } else { failed = true }
        report(counting: since != nil)
    }

    private func report(counting: Bool) {
        let now = Date()
        if let since { waitedMs += Int(now.timeIntervalSince(since) * 1000) }
        since = counting ? now : nil
        tick?.cancel()
        if counting && !loaded {
            tick = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.report(counting: true)
            }
        }
        let next = SatelliteStatus.of(loaded: loaded, failed: failed, waitedMs: waitedMs)
        guard next != status else { return }
        status = next
        onChange(next)
    }
}

/// A label with room around its text, for the chip.
final class InsetLabel: UILabel {
    private let insets: UIEdgeInsets

    init(insets: UIEdgeInsets) {
        self.insets = insets
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines lines: Int) -> CGRect {
        let inner = super.textRect(forBounds: bounds.inset(by: insets), limitedToNumberOfLines: lines)
        return inner.inset(by: UIEdgeInsets(top: -insets.top, left: -insets.left, bottom: -insets.bottom, right: -insets.right))
    }
}