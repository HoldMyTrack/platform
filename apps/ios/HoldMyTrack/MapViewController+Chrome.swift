import HoldMyTrackCore
import MapLibre
import UIKit

/// Whether Satellite imagery loads on this device (root docs/SPEC.md FR-4.10), decided by
/// HoldMyTrackCore's SatelliteStatus.
extension MapViewController {
    /// The imagery's status changed: the look follows, the layer stays as switched.
    func onImagery(_ status: SatelliteStatus) {
        state.satelliteFailed = status == .failed
        render()
        renderImageryNotice()
        exportLookChanged()
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

/// Satellite's watch, for MapViewController+Chrome.
@MainActor
final class MapChromeViews {
    let satellite: SatelliteWatch

    init(onImagery: @escaping (SatelliteStatus) -> Void) {
        satellite = SatelliteWatch(onChange: onImagery)
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
