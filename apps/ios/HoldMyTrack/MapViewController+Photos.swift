import HoldMyTrackCore
import MapLibre
import UIKit

/// Photos on the map (apps/android/docs/SPEC.md FR-2.10): the scope's photos (PhotoMarkers.scope)
/// as markers on their routes, the popup a marker's tap opens, and the viewer it leads to.
extension MapViewController {
    /// Whose photos show now: the Edit window's activity while it edits one, else the focus,
    /// else the open Story; none in Fog.
    private var photoScope: PhotoScope? {
        PhotoMarkers.scope(mode: state.mode, editWindowIDs: photos.editIDs, focused: session.panel.focused, storyID: session.storyID)
    }

    /// The photos for the scope now: read when the scope moves, or with force when they may have
    /// changed (a reprocess, a Story's members). A new scope starts empty rather than showing the
    /// last one's while it loads.
    func refreshPhotos(force: Bool) {
        let next = photoScope
        if next == photos.scope && !force {
            renderPhotos()
            return
        }
        if next != photos.scope {
            photos.items = []
            photoViews.popup.close()
        }
        photos.scope = next
        photos.task?.cancel()
        renderPhotos()
        guard let next else { return }
        photos.task = Task { [weak self] in
            let read = try? await self?.flow.api.photos(next)
            guard let self, !Task.isCancelled, self.photos.scope == next else { return }
            // A failed read keeps what showed; the next refresh tries again.
            guard let read else { return }
            self.photos.items = read
            self.photoViews.popup.retain(read)
            self.photoViews.viewer?.update(self.photoViews.popup.photos, index: self.photoViews.popup.index)
            self.renderPhotos()
        }
    }

    /// The markers: the scope's photos on their tracks, with the Photos tab's unsaved changes
    /// merged in, unless its route is hidden.
    func renderPhotos() {
        // The Track tab has the map to itself.
        let shown = trackEdit.shape == nil && PhotoMarkers.shown(photos.scope, mapHidden: session.panel.mapHidden)
        if !shown { photoViews.popup.close() }
        let overlay = photos.overlay
        let items = shown ? PhotoMarkers.items(photos.items, mapHidden: session.panel.mapHidden, overlay: overlay) : []
        photoViews.markers.set(items, activeID: overlay?.activeID ?? photoViews.popup.showingID, loneID: overlay?.activeID, on: mapView)
    }

    /// The Photos tab's draft moved: the markers follow it.
    func setPhotoOverlay(_ overlay: PhotoMarkerOverlay?) {
        guard overlay != photos.overlay else { return }
        photos.overlay = overlay
        if overlay != nil { photoViews.popup.close() }
        renderPhotos()
    }

    /// The Edit window closed: back to the saved photos, read again when any was written.
    func photosEditClosed(saved: Bool) {
        photos.editIDs = nil
        photos.overlay = nil
        photoViews.images.forgetLocal()
        refreshPhotos(force: saved)
    }

    /// The camera came to rest: what overlaps depends on the zoom.
    func regroupPhotos() {
        photoViews.markers.regroup(on: mapView)
        placePhotoPopup()
    }

    /// The camera is moving: every marker and the popup stay on their points.
    func placePhotos() {
        photoViews.markers.place(on: mapView)
        placePhotoPopup()
    }

    /// The popup's views and their callbacks, once the map's view exists.
    func bindPhotos() {
        photoViews.popup.onChange = { [weak self] _ in self?.renderPhotos() }
        photoViews.popup.onFullSize = { [weak self] group, index in self?.openViewer(group, at: index) }
    }

    /// A marker's tap: a spread group zooms in to split (PhotoMarkers.groupFit), else the popup
    /// opens on its first photo. The place's popup closes for it.
    func openPhotos(_ ids: [String]) {
        let byID = Dictionary(photos.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let located = ids.compactMap { byID[$0] }.filter { $0.lat != nil && $0.lon != nil }
        if let box = PhotoMarkers.groupFit(located.map { (lon: $0.lon!, lat: $0.lat!) }) {
            fit(box, animated: true, maxZoom: PhotoMarkers.groupMaxZoom)
            return
        }
        guard !located.isEmpty else { return }
        spotViews.popup.close()
        closeFogPlace()
        photoViews.popup.show(located)
        placePhotoPopup()
    }

    func placePhotoPopup() {
        guard let anchor = photoViews.popup.photos.first, let lat = anchor.lat, let lon = anchor.lon else { return }
        let point = mapView.convert(CLLocationCoordinate2D(latitude: lat, longitude: lon), toPointTo: view)
        photoViews.popup.place(at: point, top: chromeBottom)
    }

    /// The viewer on the photo showing, from the copy the popup holds or the thumbnail while the
    /// stored copy loads.
    private func openViewer(_ group: [Photo], at index: Int) {
        let viewer = PhotoViewerViewController(
            images: photoViews.images, format: format, photos: group, index: index,
            preview: { [weak self] photo in self?.photoViews.images.cached(photo.thumbURL) },
            onIndex: { [weak self] at in self?.photoViews.popup.showAt(at) }
        )
        photoViews.viewer = viewer
        present(viewer, animated: true)
    }
}

/// The scope, its photos and the read under way.
struct PhotosState {
    var scope: PhotoScope?
    /// The scope's saved photos, in route order.
    var items: [Photo] = []
    var task: Task<Void, Never>?
    /// The Edit window's activities while it's open.
    var editIDs: [String]?
    /// The Photos tab's unsaved changes, while it shows.
    var overlay: PhotoMarkerOverlay?
}

/// The marker layer, the popup and the viewer, sharing one image cache.
@MainActor
final class PhotoViews {
    let images: PhotoImages
    let markers: PhotoMarkersView
    let popup: PhotoPopupView
    weak var viewer: PhotoViewerViewController?

    init(api: APIClient, format: @escaping () -> PanelFormat, onOpen: @escaping ([String]) -> Void) {
        images = PhotoImages(api: api)
        markers = PhotoMarkersView(images: images, onOpen: onOpen)
        popup = PhotoPopupView(images: images, format: format)
    }
}
