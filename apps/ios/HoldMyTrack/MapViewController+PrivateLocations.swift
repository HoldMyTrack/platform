import HoldMyTrackCore
import MapLibre
import UIKit

/// The Private location editor on the map (root docs/SPEC.md FR-7.1,
/// apps/android/docs/SPEC.md FR-2.7), opened from Privacy: the map switches to Normal, the sheet steps aside for the card,
/// and every Private location is drawn, the one being edited stronger with a handle at its centre
/// to drag it by. A new one is 200 m at the middle of the map left showing, flying in first from
/// too far out; a tap on another circle opens that one. Cancel, a mode change or leaving the Map
/// tab drops the draft. The circles are the app's own source and layers, added on every style
/// load as the track editor's are, and drawn only while the editor is open: they point straight
/// at the places they hide.
extension MapViewController {
    static let privateSource = "private-locations"
    private static let privateFill = "private-locations-fill"
    private static let privateCenter = "private-locations-center"
    private static let privateHandle = "private-locations-handle"

    // MARK: Opening and closing

    /// Opens the editor on a saved location's id, or on a new one (nil).
    func editPrivateLocation(_ id: String?) {
        loadViewIfNeeded()
        guard !account.isDemo else { return }
        if pickedMode != .normal { pickMode(.normal) }
        closeFogPlace()
        spotViews.popup.close()
        photoViews.popup.close()
        let editing = privateLocations
        editing.open = true
        editing.opening += 1
        let opening = editing.opening
        editing.draft = nil
        editing.locations = nil
        renderPanel()
        Task {
            do {
                let list = try await flow.api.privateLocations()
                guard editing.open, editing.opening == opening else { return }
                editing.locations = list
                if let id {
                    guard let location = list.first(where: { $0.id == id }) else { return closePrivateEditor() }
                    openDraft(PrivateLocationEditing.Draft(location))
                    flyToDraft(zoom: PrivateLocationEditing.openZoom(mapView.zoomLevel))
                } else {
                    openNewDraft()
                }
            } catch {
                guard editing.opening == opening else { return }
                closePrivateEditor()
                StoryDialogs.inform(over: view, (error as? APIError)?.serverMessage ?? String(localized: "Private locations couldn't load."))
            }
        }
    }

    /// Gives the map back: the circles and any unsaved draft go.
    func closePrivateEditor() {
        let editing = privateLocations
        guard editing.open else { return }
        editing.open = false
        editing.draft = nil
        editing.busy = false
        editing.editor.close()
        drawPrivateLocations()
        renderPanel()
    }

    private func openDraft(_ draft: PrivateLocationEditing.Draft) {
        privateLocations.draft = draft
        privateLocations.editor.open(draft)
        renderPrivateEditor()
    }

    /// A new one at the middle of the map left showing between the controls and the card.
    private func openNewDraft() {
        privateLocations.editor.isHidden = false
        view.layoutIfNeeded()
        let open = privateOpenArea
        let middle = CGPoint(x: view.bounds.midX, y: (open.top + view.bounds.height - open.bottom) / 2)
        let at = mapView.convert(middle, toCoordinateFrom: view)
        openDraft(.new(lon: at.longitude, lat: at.latitude))
        flyToDraft(zoom: PrivateLocationEditing.placeZoom(mapView.zoomLevel))
    }

    /// The map's room above the card and below the controls.
    private var privateOpenArea: UIEdgeInsets {
        UIEdgeInsets(top: chromeBottom, left: 0, bottom: view.bounds.height - privateLocations.editor.frame.minY, right: 0)
    }

    private func flyToDraft(zoom: Double) {
        guard let draft = privateLocations.draft else { return }
        view.layoutIfNeeded()
        let center = CLLocationCoordinate2D(latitude: draft.lat, longitude: draft.lon)
        let altitude = MLNAltitudeForZoomLevel(zoom, 0, draft.lat, mapView.bounds.size)
        let camera = MLNMapCamera(lookingAtCenter: center, altitude: altitude, pitch: 0, heading: mapView.direction)
        mapView.setCamera(camera, withDuration: 0.6, animationTimingFunction: nil, edgePadding: privateOpenArea, completionHandler: nil)
    }

    // MARK: The card

    func bindPrivateEditor() {
        let editor = privateLocations.editor
        editor.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(editor)
        NSLayoutConstraint.activate([
            editor.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            editor.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        editor.onName = { [weak self] name in self?.changeDraft { $0.name = name } }
        editor.onRadius = { [weak self] radius in self?.changeDraft { $0.radiusM = radius } }
        editor.onCancel = { [weak self] in self?.closePrivateEditor() }
        editor.onSave = { [weak self] in self?.savePrivateLocation() }
        editor.onDelete = { [weak self] in self?.confirmPrivateDelete() }

        privateLocations.gestures.map = self
        addExclusiveDrag(privateLocations.gestures, action: #selector(PrivateLocationGestures.dragged(_:)))
    }

    func changeDraft(_ change: (inout PrivateLocationEditing.Draft) -> Void) {
        guard var draft = privateLocations.draft else { return }
        change(&draft)
        privateLocations.draft = draft
        renderPrivateEditor()
    }

    private func renderPrivateEditor() {
        let editing = privateLocations
        guard let draft = editing.draft else { return }
        editing.editor.render(draft, dirty: PrivateLocationEditing.dirty(draft, saved: editing.locations ?? []), busy: editing.busy)
        drawPrivateLocations()
    }

    // MARK: Save and delete

    private func savePrivateLocation() {
        let editing = privateLocations
        guard let draft = editing.draft, !editing.busy else { return }
        editing.busy = true
        editing.editor.show(error: nil)
        renderPrivateEditor()
        let opening = editing.opening
        Task {
            do {
                _ = try await flow.api.savePrivateLocation(
                    id: draft.id, name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    lon: draft.lon, lat: draft.lat, radiusM: draft.radiusM)
                privateLocationsChanged()
                guard editing.opening == opening else { return }
                editing.busy = false
                closePrivateEditor()
            } catch {
                guard editing.opening == opening else { return }
                editing.busy = false
                editing.editor.show(error: (error as? APIError)?.serverMessage ?? String(localized: "The Private location couldn't be saved."))
                renderPrivateEditor()
            }
        }
    }

    private func confirmPrivateDelete() {
        guard let id = privateLocations.draft?.id else { return }
        let alert = UIAlertController(
            title: String(localized: "Delete this Private location?"),
            message: String(localized: "Activities that start or end inside it will show those parts again once they're reprocessed.",
                            comment: "Private location editor: what deleting a Private location brings back."),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Delete"), style: .destructive) { [weak self] _ in
            self?.deletePrivateLocation(id)
        })
        present(alert, animated: true)
    }

    private func deletePrivateLocation(_ id: String) {
        let editing = privateLocations
        editing.busy = true
        renderPrivateEditor()
        let opening = editing.opening
        Task {
            do {
                try await flow.api.deletePrivateLocation(id)
                privateLocationsChanged()
                guard editing.opening == opening else { return }
                editing.busy = false
                closePrivateEditor()
            } catch {
                guard editing.opening == opening else { return }
                editing.busy = false
                editing.editor.show(error: (error as? APIError)?.serverMessage ?? String(localized: "The Private location couldn't be deleted."))
                renderPrivateEditor()
            }
        }
    }

    /// A change reprocesses every activity it touches, which the server marks Pending with the
    /// change itself: the list shows them at once, and the tracks are fetched again once coverage
    /// stops rendering, the listed ones and any off the list alike. A newer change's wait
    /// replaces this one's.
    private func privateLocationsChanged() {
        loadList()
        privateLocations.refresh?.cancel()
        privateLocations.refresh = Task {
            for _ in 0..<90 {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                // A failed check waits for the next, rather than leaving the tracks unclipped.
                if let status = try? await flow.api.coverageStatus(), !status.rendering { break }
            }
            guard !Task.isCancelled else { return }
            tracksVersion += 1
            updateTracksQuery()
            render()
            loadList()
        }
    }

    // MARK: The map

    /// A tap while the editor has the map: another saved circle opens that one.
    func privateLocationTapped(at point: CGPoint) {
        let editing = privateLocations
        guard !editing.busy, let locations = editing.locations else { return }
        guard case .saved(let id) = privateHit(at: point), let location = locations.first(where: { $0.id == id }) else { return }
        openDraft(PrivateLocationEditing.Draft(location))
    }

    private func privateHit(at point: CGPoint) -> PrivateLocationEditing.Hit {
        let r: CGFloat = 20
        let near = mapView.visibleFeatures(in: CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r),
                                           styleLayerIdentifiers: [Self.privateHandle, Self.privateCenter])
        let inside = mapView.visibleFeatures(at: point, styleLayerIdentifiers: [Self.privateFill])
        return PrivateLocationEditing.hit((near + inside).map {
            (($0.attribute(forKey: "id") as? String) ?? "", ($0.attribute(forKey: "selected") as? Bool) ?? false)
        })
    }

    /// Whether a press at point grabs the handle of the circle being edited.
    func onPrivateHandle(_ point: CGPoint) -> Bool {
        let editing = privateLocations
        guard editing.open, editing.draft != nil, !editing.busy else { return false }
        let r: CGFloat = 20
        return !mapView.visibleFeatures(in: CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r),
                                        styleLayerIdentifiers: [Self.privateHandle]).isEmpty
    }

    /// The source and layers onto a style just loaded, under the basemap's labels.
    func addPrivateLocations(to style: MLNStyle) {
        guard style.source(withIdentifier: Self.privateSource) == nil else { return }
        let source = MLNShapeSource(identifier: Self.privateSource, shape: privateShape())
        style.addSource(source)
        let color = UIColor(red: 0x7a / 255, green: 0x4b / 255, blue: 0xc2 / 255, alpha: 1)
        let selected: [Any] = ["boolean", ["get", "selected"], false]
        let fill = MLNFillStyleLayer(identifier: Self.privateFill, source: source)
        fill.predicate = NSPredicate(format: "role == 'circle'")
        fill.fillColor = NSExpression(forConstantValue: color)
        fill.fillOpacity = NSExpression(mglJSONObject: ["case", selected, 0.3, 0.16] as [Any])
        let outline = MLNLineStyleLayer(identifier: "private-locations-outline", source: source)
        outline.predicate = NSPredicate(format: "role == 'circle'")
        outline.lineColor = NSExpression(forConstantValue: color)
        outline.lineWidth = NSExpression(mglJSONObject: ["case", selected, 2.5, 1.5] as [Any])
        func dot(_ id: String, _ role: String, radius: Double, stroke: Double) -> MLNCircleStyleLayer {
            let layer = MLNCircleStyleLayer(identifier: id, source: source)
            layer.predicate = NSPredicate(format: "role == %@", role)
            layer.circleRadius = NSExpression(forConstantValue: radius)
            layer.circleColor = NSExpression(forConstantValue: color)
            layer.circleStrokeColor = NSExpression(forConstantValue: UIColor.white)
            layer.circleStrokeWidth = NSExpression(forConstantValue: stroke)
            return layer
        }
        let below = style.layers.first { $0 is MLNSymbolStyleLayer }
        for layer in [fill, outline, dot(Self.privateCenter, "center", radius: 5, stroke: 1.5), dot(Self.privateHandle, "handle", radius: 8, stroke: 2.5)] as [MLNStyleLayer] {
            layer.minimumZoomLevel = Float(PrivateLocationEditing.minZoom)
            if let below { style.insertLayer(layer, below: below) } else { style.addLayer(layer) }
        }
    }

    func drawPrivateLocations() {
        (mapView.style?.source(withIdentifier: Self.privateSource) as? MLNShapeSource)?.shape = privateShape()
    }

    /// Every saved circle, with the draft in place of its saved copy; nothing while closed.
    private func privateShape() -> MLNShape {
        let editing = privateLocations
        guard editing.open else { return MLNShapeCollectionFeature(shapes: []) }
        var features: [MLNShape & MLNFeature] = []
        func add(id: String, lon: Double, lat: Double, radiusM: Int, selected: Bool) {
            var ring = PrivateLocationEditing.ring(lon: lon, lat: lat, radiusM: radiusM).map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            let circle = MLNPolygonFeature(coordinates: &ring, count: UInt(ring.count))
            circle.attributes = ["role": "circle", "id": id, "selected": selected]
            let center = MLNPointFeature()
            center.coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            center.attributes = ["role": selected ? "handle" : "center", "id": id, "selected": selected]
            features += [circle, center]
        }
        let draft = editing.draft
        for l in editing.locations ?? [] where l.id != draft?.id {
            add(id: l.id, lon: l.lon, lat: l.lat, radiusM: l.radiusM, selected: false)
        }
        if let draft { add(id: draft.id ?? "", lon: draft.lon, lat: draft.lat, radiusM: draft.radiusM, selected: true) }
        return MLNShapeCollectionFeature(shapes: features)
    }
}

/// The editor's card, its draft and the saved list it edits.
@MainActor
final class PrivateLocationsState {
    let editor = PrivateLocationEditorView()
    let gestures = PrivateLocationGestures()
    /// The map is the editor's.
    var open = false
    /// Counts openings, so an answer for one since closed changes nothing.
    var opening = 0
    /// The tracks' refresh after a save or delete.
    var refresh: Task<Void, Never>?
    var locations: [PrivateLocation]?
    var draft: PrivateLocationEditing.Draft?
    var busy = false
}

/// The handle's drag: it begins only on the handle, so every other pan still moves the map.
@MainActor
final class PrivateLocationGestures: NSObject, UIGestureRecognizerDelegate {
    weak var map: MapViewController?

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let map else { return false }
        return map.onPrivateHandle(gesture.location(in: map.mapView))
    }

    /// From the finger to the handle, kept through the drag so the circle doesn't jump to it.
    private var offset = CGVector.zero

    @objc func dragged(_ gesture: UIPanGestureRecognizer) {
        guard let map, let draft = map.privateLocations.draft else { return }
        let finger = gesture.location(in: map.mapView)
        if gesture.state == .began {
            let handle = map.mapView.convert(CLLocationCoordinate2D(latitude: draft.lat, longitude: draft.lon), toPointTo: map.mapView)
            offset = CGVector(dx: handle.x - finger.x, dy: handle.y - finger.y)
        }
        guard gesture.state == .began || gesture.state == .changed else { return }
        let at = map.mapView.convert(CGPoint(x: finger.x + offset.dx, y: finger.y + offset.dy), toCoordinateFrom: map.mapView)
        map.changeDraft {
            $0.lon = at.longitude
            $0.lat = at.latitude
        }
    }
}