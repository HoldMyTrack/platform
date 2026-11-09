import HoldMyTrackCore
import UIKit

/// The focused activity's pace bands (root docs/SPEC.md FR-4.8): its metrics fetched when the
/// focus moves, again after its reprocess lands, and dropped when it clears; drawn by the layers
/// document's `track-bands` group while its track is drawn (PaceBands.drawn), with the legend on
/// its card.
extension MapViewController {
    /// The focus moved, or with refetch a reprocess landed. Binds what's drawn into the state;
    /// the caller renders.
    func updateBands(refetch: Bool = false) {
        let focused = session.panel.focused
        if focused != bands.metrics?.activityID || refetch {
            if !refetch { bands.metrics = nil }
            bands.task?.cancel()
            bands.task = focused.map { id in
                Task { [weak self] in
                    let metrics = try? await self?.flow.api.trackMetrics(id)
                    guard let self, !Task.isCancelled, self.session.panel.focused == id else { return }
                    self.bands.metrics = metrics
                    self.drawBands()
                    self.render()
                }
            }
        }
        drawBands()
    }

    private func drawBands() {
        let drawn = PaceBands.drawn(bands.metrics, focused: session.panel.focused, mapHidden: session.panel.mapHidden)
        state.geojson[PaceBands.group] = PaceBands.features(drawn)
        activitiesPanel.setBands(drawn == nil ? nil : pair.map { PaceBands.colors($0.layers) })
    }
}

/// The metrics last fetched for the focused activity, and the fetch under way.
struct BandsState {
    var metrics: TrackMetrics?
    var task: Task<Void, Never>?
}
