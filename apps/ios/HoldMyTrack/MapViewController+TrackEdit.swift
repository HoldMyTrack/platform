import HoldMyTrackCore
import MapLibre
import UIKit

/// The track being edited, drawn over the map (root docs/SPEC.md FR-5.14), Android's
/// TrackEditOverlay: what the edit keeps in the accent, what it would take out dashed in red, a
/// split's second part in blue, every point as a small ring, and the knobs. The app's own source
/// and layers, added on every style load as capture's guide is, under the basemap's labels. While
/// the Track tab shows, every other track, the pace bands and the photos step aside.
extension MapViewController {
    static let trackEditSource = "track-edit"
    static let trackEditPoints = "track-edit-points"

    /// The editor's drawing, or nil once its tab closes.
    func setTrackEdit(_ shape: TrackEditDrawing.Shape?) {
        let was = trackEdit.shape != nil
        trackEdit.shape = shape
        (mapView.style?.source(withIdentifier: Self.trackEditSource) as? MLNShapeSource)?.shape = Self.features(shape)
        if was != (shape != nil) { panelChanged() }
    }

    /// The Track tab opened: the camera onto the activity, clear of the half-height sheet.
    func frameEditedTrack(_ activity: Activity) {
        guard let box = activity.bbox else { return }
        let bounds = MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: box[1], longitude: box[0]),
                                         ne: CLLocationCoordinate2D(latitude: box[3], longitude: box[2]))
        let padding = UIEdgeInsets(top: chromeBottom + 16, left: 32, bottom: view.bounds.height / 2 + 24, right: 32)
        mapView.setVisibleCoordinateBounds(bounds, edgePadding: padding, animated: true, completionHandler: nil)
    }

    /// The tracks the map hides: the panel's, and while the Track tab shows, every one.
    var hiddenTracks: [String] {
        trackEdit.shape == nil ? session.panel.mapHidden.sorted() : activities.map(\.id)
    }

    /// The overlay's source and layers onto a style just loaded.
    func addTrackEdit(to style: MLNStyle) {
        guard style.source(withIdentifier: Self.trackEditSource) == nil else { return }
        let source = MLNShapeSource(identifier: Self.trackEditSource, shape: Self.features(trackEdit.shape))
        style.addSource(source)
        let accent = UIColor(red: 0xb0 / 255, green: 0x7e / 255, blue: 0x2e / 255, alpha: 1)
        let removed = UIColor(red: 0xc5 / 255, green: 0x30 / 255, blue: 0x30 / 255, alpha: 1)
        let second = UIColor(red: 0x2b / 255, green: 0x6c / 255, blue: 0xb0 / 255, alpha: 1)
        func line(_ id: String, _ role: String, _ color: UIColor, width: Double, opacity: Double, dashed: Bool = false) -> MLNLineStyleLayer {
            let layer = MLNLineStyleLayer(identifier: id, source: source)
            layer.predicate = NSPredicate(format: "role == %@", role)
            layer.lineColor = NSExpression(forConstantValue: color)
            layer.lineWidth = NSExpression(forConstantValue: width)
            layer.lineOpacity = NSExpression(forConstantValue: opacity)
            layer.lineCap = NSExpression(forConstantValue: "round")
            layer.lineJoin = NSExpression(forConstantValue: "round")
            if dashed { layer.lineDashPattern = NSExpression(forConstantValue: [1.5, 1.5]) }
            return layer
        }
        let points = MLNCircleStyleLayer(identifier: Self.trackEditPoints, source: source)
        points.predicate = NSPredicate(format: "role == 'point'")
        points.circleRadius = NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"], 12, 1.5, 16, 3, 19, 5])
        points.circleColor = NSExpression(forConstantValue: UIColor.white)
        // Dense at street zoom, the rings cover the line, so they take its part's color too.
        points.circleStrokeColor = NSExpression(mglJSONObject: ["case", ["get", "removed"], removed, ["get", "second"], second, accent] as [Any])
        points.circleStrokeWidth = NSExpression(forConstantValue: 1.2)
        points.circleOpacity = NSExpression(mglJSONObject: ["case", ["get", "removed"], 0.5, 1])
        points.circleStrokeOpacity = NSExpression(mglJSONObject: ["case", ["get", "removed"], 0.5, 1])
        let knobs = MLNCircleStyleLayer(identifier: "track-edit-knobs", source: source)
        knobs.predicate = NSPredicate(format: "role == 'knob'")
        knobs.circleRadius = NSExpression(forConstantValue: 7)
        knobs.circleColor = NSExpression(forConstantValue: accent)
        knobs.circleStrokeColor = NSExpression(forConstantValue: UIColor.white)
        knobs.circleStrokeWidth = NSExpression(forConstantValue: 2.5)
        let below = style.layers.first { $0 is MLNSymbolStyleLayer }
        for layer in [line("track-edit-preview", "preview", removed, width: 3, opacity: 0.55, dashed: true),
                      line("track-edit-line", "kept", accent, width: 4, opacity: 0.95),
                      line("track-edit-second", "second", second, width: 4, opacity: 0.95), points, knobs] as [MLNStyleLayer] {
            if let below { style.insertLayer(layer, below: below) } else { style.addLayer(layer) }
        }
    }

    private static func features(_ shape: TrackEditDrawing.Shape?) -> MLNShape {
        guard let shape else { return MLNShapeCollectionFeature(shapes: []) }
        func coordinate(_ p: TrackPoint) -> CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon) }
        var features: [MLNShape & MLNFeature] = shape.lines.map { role, points in
            let line = MLNPolylineFeature(coordinates: points.map(coordinate), count: UInt(points.count))
            line.attributes = ["role": role]
            return line
        }
        for p in shape.points {
            let point = MLNPointFeature()
            point.coordinate = coordinate(p.point)
            point.attributes = ["role": "point", "t": p.point.t, "removed": p.removed, "second": p.second]
            features.append(point)
        }
        for k in shape.knobs {
            let knob = MLNPointFeature()
            knob.coordinate = coordinate(k)
            knob.attributes = ["role": "knob"]
            features.append(knob)
        }
        return MLNShapeCollectionFeature(shapes: features)
    }

    /// The time of the drawn point nearest point on the map view, within a fingertip, or nil.
    func trackEditPoint(at point: CGPoint) -> Int? {
        let r: CGFloat = 16
        let rect = CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r)
        return mapView.visibleFeatures(in: rect, styleLayerIdentifiers: [Self.trackEditPoints]).compactMap { feature -> (Int, CGFloat)? in
            guard let t = (feature.attribute(forKey: "t") as? NSNumber)?.intValue else { return nil }
            let at = mapView.convert(feature.coordinate, toPointTo: mapView)
            return (t, hypot(at.x - point.x, at.y - point.y))
        }.min { $0.1 < $1.1 }?.0
    }

    /// A tap while the Edit window is open: Delete point's, on the point under it.
    func trackEditTapped(at point: CGPoint) {
        guard let editor = editWindow?.trackEditor, editor.deleteMode, let t = trackEditPoint(at: point) else { return }
        editor.dropPoint(t)
    }

    /// Move point's drag: a press on a point takes the gesture from the map, which stays put.
    func bindTrackEditDrag() {
        let drag = UIPanGestureRecognizer(target: trackEdit.gestures, action: #selector(TrackEditGestures.dragged(_:)))
        drag.delegate = trackEdit.gestures
        trackEdit.gestures.map = self
        for pan in mapView.gestureRecognizers ?? [] where pan is UIPanGestureRecognizer { pan.require(toFail: drag) }
        mapView.addGestureRecognizer(drag)
    }
}

/// The overlay's drawing and the drag that moves its points.
@MainActor
struct TrackEditState {
    var shape: TrackEditDrawing.Shape?
    let gestures = TrackEditGestures()
}

/// Move point's gesture: it begins only on a point while Move point is on, so every other pan
/// still moves the map.
@MainActor
final class TrackEditGestures: NSObject, UIGestureRecognizerDelegate {
    weak var map: MapViewController?

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let map, let editor = map.editWindow?.trackEditor, editor.moveMode,
              let t = map.trackEditPoint(at: gesture.location(in: map.mapView)) else { return false }
        return editor.beginMove(t)
    }

    @objc func dragged(_ gesture: UIPanGestureRecognizer) {
        guard let map, let editor = map.editWindow?.trackEditor else { return }
        switch gesture.state {
        case .changed:
            let at = map.mapView.convert(gesture.location(in: map.mapView), toCoordinateFrom: map.mapView)
            editor.moveTo(lon: at.longitude, lat: at.latitude)
        case .ended: editor.endMove(commit: true)
        case .cancelled, .failed: editor.endMove(commit: false)
        default: break
        }
    }
}
