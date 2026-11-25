import HoldMyTrackCore
import MapLibre
import UIKit

/// The track being edited, drawn over the map (root docs/SPEC.md FR-5.7), Android's
/// TrackEditOverlay: what the edit keeps in the accent, what it would take out dashed in red, a
/// split's second part in blue, every point as a small ring, and the knobs. The app's own source
/// and layers, added on every style load as capture's guide is, under the basemap's labels. While
/// the Route tab shows, every other track, the pace bands and the photos step aside.
extension MapViewController {
    static let routeEditSource = "route-edit"
    static let routeEditPoints = "route-edit-points"

    /// The editor's drawing, or nil once its tab closes.
    func setRouteEdit(_ shape: RouteEditDrawing.Shape?) {
        let was = routeEdit.shape != nil
        routeEdit.shape = shape
        (mapView.style?.source(withIdentifier: Self.routeEditSource) as? MLNShapeSource)?.shape = Self.features(shape)
        guard was != (shape != nil) else { return }
        if !was {
            // The route editor has the map: a capture stops, and the places step aside.
            capturing.stop()
            spotViews.popup.close()
        }
        applyTabMode()
        panelChanged()
    }

    /// The Route tab opened: the camera onto the track, clear of the Edit sheet.
    /// covered: how much of the map's bottom the Edit sheet takes once it has its new height.
    func frameEditedTrack(_ track: Track, covered: CGFloat) {
        guard let box = track.bbox else { return }
        let bounds = MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: box[1], longitude: box[0]),
                                         ne: CLLocationCoordinate2D(latitude: box[3], longitude: box[2]))
        let padding = UIEdgeInsets(top: chromeBottom + 16, left: 32, bottom: covered + 24, right: 32)
        mapView.setVisibleCoordinateBounds(bounds, edgePadding: padding, animated: true, completionHandler: nil)
    }

    /// The tracks the map hides: the panel's, and while the Route tab shows, every one.
    var hiddenTracks: [String] {
        routeEdit.shape == nil ? session.panel.mapHidden.sorted() : tracks.map(\.id)
    }

    /// The overlay's source and layers onto a style just loaded.
    func addRouteEdit(to style: MLNStyle) {
        guard style.source(withIdentifier: Self.routeEditSource) == nil else { return }
        let source = MLNShapeSource(identifier: Self.routeEditSource, shape: Self.features(routeEdit.shape))
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
        let points = MLNCircleStyleLayer(identifier: Self.routeEditPoints, source: source)
        points.predicate = NSPredicate(format: "role == 'point'")
        points.circleRadius = NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"], 12, 1.5, 16, 3, 19, 5])
        points.circleColor = NSExpression(forConstantValue: UIColor.white)
        // Dense at street zoom, the rings cover the line, so they take its part's color too.
        points.circleStrokeColor = NSExpression(mglJSONObject: ["case", ["get", "removed"], removed, ["get", "second"], second, accent] as [Any])
        points.circleStrokeWidth = NSExpression(forConstantValue: 1.2)
        points.circleOpacity = NSExpression(mglJSONObject: ["case", ["get", "removed"], 0.5, 1])
        points.circleStrokeOpacity = NSExpression(mglJSONObject: ["case", ["get", "removed"], 0.5, 1])
        let knobs = MLNCircleStyleLayer(identifier: "route-edit-knobs", source: source)
        knobs.predicate = NSPredicate(format: "role == 'knob'")
        knobs.circleRadius = NSExpression(forConstantValue: 7)
        knobs.circleColor = NSExpression(forConstantValue: accent)
        knobs.circleStrokeColor = NSExpression(forConstantValue: UIColor.white)
        knobs.circleStrokeWidth = NSExpression(forConstantValue: 2.5)
        let below = style.layers.first { $0 is MLNSymbolStyleLayer }
        for layer in [line("route-edit-preview", "preview", removed, width: 3, opacity: 0.55, dashed: true),
                      line("route-edit-line", "kept", accent, width: 4, opacity: 0.95),
                      line("route-edit-second", "second", second, width: 4, opacity: 0.95), points, knobs] as [MLNStyleLayer] {
            if let below { style.insertLayer(layer, below: below) } else { style.addLayer(layer) }
        }
    }

    private static func features(_ shape: RouteEditDrawing.Shape?) -> MLNShape {
        guard let shape else { return MLNShapeCollectionFeature(shapes: []) }
        func coordinate(_ p: RoutePoint) -> CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon) }
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
    func routeEditPoint(at point: CGPoint) -> Int? {
        let r: CGFloat = 16
        let rect = CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r)
        return mapView.visibleFeatures(in: rect, styleLayerIdentifiers: [Self.routeEditPoints]).compactMap { feature -> (Int, CGFloat)? in
            guard let t = (feature.attribute(forKey: "t") as? NSNumber)?.intValue else { return nil }
            let at = mapView.convert(feature.coordinate, toPointTo: mapView)
            return (t, hypot(at.x - point.x, at.y - point.y))
        }.min { $0.1 < $1.1 }?.0
    }

    /// A tap while the Edit window is open: Delete point's, on the point under it.
    func routeEditTapped(at point: CGPoint) {
        guard let editor = editWindow?.routeEditor, editor.deleteMode, let t = routeEditPoint(at: point) else { return }
        editor.dropPoint(t)
    }

    /// Move point's drag: a press on a point takes the gesture from the map, which stays put.
    func bindRouteEditDrag() {
        routeEdit.gestures.map = self
        addExclusiveDrag(routeEdit.gestures, action: #selector(RouteEditGestures.dragged(_:)))
    }

    /// A pan that, when its delegate lets it begin, takes the drag from the map, whose own pans
    /// wait for it to fail: so every other drag still moves the map.
    func addExclusiveDrag(_ target: NSObject & UIGestureRecognizerDelegate, action: Selector) {
        let drag = UIPanGestureRecognizer(target: target, action: action)
        drag.delegate = target
        for pan in mapView.gestureRecognizers ?? [] where pan is UIPanGestureRecognizer { pan.require(toFail: drag) }
        mapView.addGestureRecognizer(drag)
    }
}

/// The overlay's drawing and the drag that moves its points.
@MainActor
struct RouteEditState {
    var shape: RouteEditDrawing.Shape?
    let gestures = RouteEditGestures()
}

/// Move point's gesture: it begins only on a point while Move point is on, so every other pan
/// still moves the map.
@MainActor
final class RouteEditGestures: NSObject, UIGestureRecognizerDelegate {
    weak var map: MapViewController?

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let map, let editor = map.editWindow?.routeEditor, editor.moveMode,
              let t = map.routeEditPoint(at: gesture.location(in: map.mapView)) else { return false }
        return editor.beginMove(t)
    }

    @objc func dragged(_ gesture: UIPanGestureRecognizer) {
        guard let map, let editor = map.editWindow?.routeEditor else { return }
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
