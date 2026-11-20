import CoreLocation
import HoldMyTrackCore
import MapLibre
import UIKit

/// The recording on the map (apps/android/docs/SPEC.md FR-5.1): while one runs the map shows it and
/// nothing else, Normal with the tracks hidden and the sheet, the toggle and the export put away;
/// its line and a dot at its latest fix are the app's own source and layers, drawn from the fixes
/// the phone holds, since the server has never seen them. The camera flies to the first fix, then
/// only pans, so a zoom picked meanwhile sticks.
extension MapViewController {
    private static let recordingSource = "recording-live"

    /// The recording's state and fixes, from RecordingController.
    func showRecording(active: Bool, points: [RecordedPoint]) {
        loadViewIfNeeded()
        if active != recordingLive {
            recordingLive = active
            recordingFollowed = false
            recordingFollows = true
            if active {
                closeExport()
                closeFogPlace()
                closePrivateEditor()
                spotViews.popup.close()
                photoViews.popup.close()
            }
            // The track's photos step aside with the tracks; Spots and paths stay, as on Android,
            // being about where the recording goes.
            photoViews.markers.isHidden = active
            export.button.isHidden = active
            state.hiddenGroups = TabMode.hiddenGroups(recording: active)
            applyTabMode()
            render()
            renderPanel()
            if !active, !tourBlocked { onMapFreed?() }
        }
        drawRecording(points)
        followRecording()
    }

    /// The camera on the latest fix: flown to at the first, panned after, and left alone once the
    /// user moves the map, until Find my location.
    private func followRecording() {
        guard recordingLive, recordingFollows, let last = lastRecordingPoints.last else { return }
        let at = CLLocationCoordinate2D(latitude: last.lat, longitude: last.lon)
        recordingMoving = true
        if recordingFollowed {
            mapView.setCenter(at, animated: true)
        } else {
            recordingFollowed = true
            mapView.setCenter(at, zoomLevel: max(mapView.zoomLevel, 15), animated: true)
        }
        recordingMoving = false
    }

    /// The user moved the map while recording: the camera stops following.
    func mapView(_ mapView: MLNMapView, regionWillChangeWith reason: MLNCameraChangeReason, animated: Bool) {
        guard recordingLive, !recordingMoving, reason.contains(.gesturePan) || reason.contains(.gesturePinch) || reason.contains(.gestureRotate) else { return }
        recordingFollows = false
    }

    /// Find my location while recording: the camera follows the recording again.
    func followRecordingAgain() -> Bool {
        guard recordingLive else { return false }
        recordingFollows = true
        followRecording()
        return true
    }

    /// A recording's message over the map, for a few seconds: the last one replaces the one before.
    func say(_ text: String) {
        loadViewIfNeeded()
        hideNotice(.recording)
        notice(.recording, text)
        recordingNoticeShown += 1
        let shown = recordingNoticeShown
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.recordingNoticeShown == shown else { return }
            self.hideNotice(.recording)
        }
    }

    /// The source and layers, added on every style load and drawn from the fixes held.
    func addRecording(to style: MLNStyle) {
        guard style.source(withIdentifier: Self.recordingSource) == nil else { return }
        let source = MLNShapeSource(identifier: Self.recordingSource, shape: nil)
        style.addSource(source)
        // The tracks' own color, from the layers document; it's what the recording becomes.
        let color = recordingColor()
        let line = MLNLineStyleLayer(identifier: "recording-line", source: source)
        line.predicate = NSPredicate(format: "role == 'line'")
        line.lineColor = NSExpression(forConstantValue: color)
        line.lineWidth = NSExpression(forConstantValue: 4)
        line.lineCap = NSExpression(forConstantValue: "round")
        line.lineJoin = NSExpression(forConstantValue: "round")
        let dot = MLNCircleStyleLayer(identifier: "recording-position", source: source)
        dot.predicate = NSPredicate(format: "role == 'position'")
        dot.circleRadius = NSExpression(forConstantValue: 7)
        dot.circleColor = NSExpression(forConstantValue: color)
        dot.circleStrokeColor = NSExpression(forConstantValue: UIColor.white)
        dot.circleStrokeWidth = NSExpression(forConstantValue: 2.5)
        // Over everything, labels included: it's the one thing on the map that matters now.
        style.addLayer(line)
        style.addLayer(dot)
        drawRecording(recordingPoints)
    }

    /// The fixes last drawn, for a style that loads mid-recording.
    private var recordingPoints: [RecordedPoint] { recordingLive ? lastRecordingPoints : [] }

    private func drawRecording(_ points: [RecordedPoint]) {
        lastRecordingPoints = recordingLive ? points : []
        guard let source = mapView.style?.source(withIdentifier: Self.recordingSource) as? MLNShapeSource else { return }
        var features: [MLNShape & MLNFeature] = []
        var coordinates = lastRecordingPoints.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        if coordinates.count >= 2 {
            let line = MLNPolylineFeature(coordinates: &coordinates, count: UInt(coordinates.count))
            line.attributes = ["role": "line"]
            features.append(line)
        }
        if let last = coordinates.last {
            let dot = MLNPointFeature()
            dot.coordinate = last
            dot.attributes = ["role": "position"]
            features.append(dot)
        }
        source.shape = MLNShapeCollectionFeature(shapes: features)
    }

    /// The layers document's line color for the tracks, else the web's accent.
    private func recordingColor() -> UIColor {
        let layers = pair?.layers.groups.first { $0.id == "tracks" }?.layers ?? []
        let text = layers.first { $0["id"]?.string == "tracks-line" }?["paint"]?["line-color"]?.string
        guard let text, let c = CSSColor(text) else { return UIColor(red: 0xb0 / 255, green: 0x7e / 255, blue: 0x2e / 255, alpha: 1) }
        return UIColor(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    }
}