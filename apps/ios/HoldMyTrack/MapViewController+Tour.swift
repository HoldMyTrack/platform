import CoreLocation
import HoldMyTrackCore
import MapLibre
import UIKit

/// What the tour asks of the map (TourController): its sheet, the controls a step points at, and
/// the camera it flies through the demo's history.
extension MapViewController {
    /// The Edit window, the Private location editor or a recording has the map, which the tour
    /// and the export leave alone.
    var tourBlocked: Bool { editOpen || privateLocations.open || recordingLive }

    var tourSheetDetent: SheetDetent { sheet.detent }

    func setTourSheet(_ detent: SheetDetent) {
        loadViewIfNeeded()
        if sheet.detent != detent { sheet.setDetent(detent, animated: true) }
    }

    /// A step's mode, shown on the Tracks tab without becoming the user's pick, which the tour's
    /// end puts back.
    func showTourMode(_ mode: MapMode) {
        pickedMode = mode
        applyTabMode()
    }

    /// The views a step on the map points at. Fog's level button shows only once the layers
    /// document has its levels; until then the step points at the toggle.
    func tourViews(_ target: TourTarget) -> [UIView] {
        guard isViewLoaded else { return [] }
        return switch target {
        case .sheet: [sheet]
        case .dates: [tracksPanel.datesButton]
        case .layers: [rail.layers] + [layersMenu.content].compactMap { $0 }
        case .places: [rail.places] + [placesMenu.content].compactMap { $0 }
        case .export: [rail.export]
        case .modes: [modes]
        case .fogLevel: fogViews.menuButton.isHidden ? [modes] : [fogViews.menuButton]
        case .page, .youTour, .record: []
        }
    }

    /// The map's view now, nil before it's made.
    var tourCurrentView: TourView? {
        guard isViewLoaded else { return nil }
        let centre = mapView.centerCoordinate
        return TourView(lon: centre.longitude, lat: centre.latitude, zoom: mapView.zoomLevel)
    }

    /// Eases the camera to view over duration seconds (0 jumps), then calls then; a later move
    /// cancels it, and then isn't called.
    func tourMove(to view: TourView, duration: TimeInterval, then: @escaping () -> Void) {
        let centre = CLLocationCoordinate2D(latitude: view.lat, longitude: view.lon)
        tourSetCamera(centre: centre, zoom: view.zoom, duration: duration, then: then)
    }

    /// Pans to a point at the zoom in view, for a view's pan.
    func tourPan(lon: Double, lat: Double, duration: TimeInterval, then: @escaping () -> Void) {
        tourSetCamera(centre: CLLocationCoordinate2D(latitude: lat, longitude: lon), zoom: mapView.zoomLevel, duration: duration, then: then)
    }

    private func tourSetCamera(centre: CLLocationCoordinate2D, zoom: Double, duration: TimeInterval, then: @escaping () -> Void) {
        guard isViewLoaded else { return }
        let altitude = MLNAltitudeForZoomLevel(zoom, mapView.camera.pitch, centre.latitude, mapView.bounds.size)
        let camera = MLNMapCamera(lookingAtCenter: centre, altitude: altitude, pitch: mapView.camera.pitch, heading: mapView.camera.heading)
        tourMoves += 1
        let move = tourMoves
        mapView.setCamera(camera, withDuration: duration, animationTimingFunction: CAMediaTimingFunction(name: .easeInEaseOut)) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.tourMoves == move else { return }
                then()
            }
        }
    }

    /// Stops the tour's camera where it is: a pending pan's next leg isn't taken.
    func tourStopCamera() { tourMoves += 1 }
}