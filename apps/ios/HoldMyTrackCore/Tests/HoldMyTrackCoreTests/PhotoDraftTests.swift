import Foundation
import Testing

@testable import HoldMyTrackCore

/// The Photos tab's unsaved changes (apps/android/docs/SPEC.md FR-2.10), Android's PhotoDraftTest.
struct PhotoDraftTests {
    private func saved(_ id: String, _ routeAt: Double, caption: String? = nil) -> Photo {
        Photo(id: id, activityID: "a1", routeAt: ISOMoment.format(Date(timeIntervalSince1970: routeAt)), lon: 0, lat: 0, caption: caption,
              width: 2048, height: 1365, url: "/v1/photos/\(id)", thumbURL: "/v1/photos/\(id)/thumb")
    }

    private func new(_ key: String, _ routeAt: Double?) -> NewPhoto {
        NewPhoto(key: key, name: "\(key).jpg", prepared: PreparedPhoto(file: Data(), thumb: Data(), exif: PhotoExif()), routeAt: routeAt)
    }

    private var photos: [Photo] { [saved("p1", 100, caption: "Start"), saved("p2", 300)] }

    @Test func rowsAreInRouteOrderWithNewOnesAmongThemAndWaitingOnesLeftOut() {
        var draft = PhotoDraft()
        draft.add(new("n1", 200))
        draft.add(new("n2", nil))
        #expect(draft.rows(photos).map(\.id) == ["p1", "n1", "p2"])
        #expect(draft.waiting.map(\.key) == ["n2"])
        #expect(draft.invalid == .waiting)
    }

    @Test func aMovedPhotoTakesItsNewPlaceInTheOrder() {
        var draft = PhotoDraft()
        draft.change(photos[0], routeAt: 400)
        let rows = draft.rows(photos)
        #expect(rows.map(\.id) == ["p2", "p1"])
        guard case .saved(_, _, _, _, let changed) = rows[1] else { Issue.record("not saved"); return }
        #expect(changed)
    }

    @Test func aChangeBackToWhatsSavedIsNoChange() {
        var moved = PhotoDraft()
        moved.change(photos[0], routeAt: 150)
        #expect(!moved.isEmpty)
        moved.change(photos[0], routeAt: 100)
        #expect(moved.isEmpty)
        var captioned = PhotoDraft()
        captioned.change(photos[0], caption: "Start!")
        captioned.change(photos[0], caption: "Start")
        #expect(captioned.isEmpty)
        // An empty caption on a photo with none is no change either.
        var empty = PhotoDraft()
        empty.change(photos[1], caption: "")
        #expect(empty.isEmpty)
    }

    @Test func aMoveAndACaptionAreOneChange() {
        var draft = PhotoDraft()
        draft.change(photos[1], routeAt: 250)
        draft.change(photos[1], caption: "Lake")
        #expect(draft.changed["p2"] == PhotoChange(routeAt: 250, caption: "Lake"))
        #expect(draft.size == 1)
    }

    @Test func aDeletedPhotoStaysListedMarkedAndCanBeKept() {
        var draft = PhotoDraft()
        draft.setDeleted("p2", true)
        guard case .saved(_, _, _, let deleted, _) = draft.rows(photos).first(where: { $0.id == "p2" }) else { Issue.record("no row"); return }
        #expect(deleted)
        draft.setDeleted("p2", false)
        #expect(draft.isEmpty)
    }

    @Test func saveWritesEachAddChangeAndDeleteOnceAndAChangedThenDeletedPhotoOnlyAsADelete() {
        var draft = PhotoDraft()
        draft.add(new("n1", 200))
        draft.change(photos[0], caption: "Begin")
        draft.change(photos[1], routeAt: 250)
        draft.setDeleted("p2", true)
        #expect(draft.size == 3)
        // Each write that lands leaves the draft, so a retried Save starts from the next.
        draft.removeNew("n1")
        #expect(draft.size == 2)
        draft.changeWritten("p1")
        #expect(draft.size == 1)
        draft.deleteWritten("p2")
        #expect(draft.isEmpty)
    }

    @Test func captionsAreEveryOneSaveWouldWriteAndALongOneIsRefused() {
        var draft = PhotoDraft()
        draft.add(new("n1", 200))
        draft.changeNew("n1") { $0.caption = "New one" }
        draft.change(photos[1], caption: "Lake")
        draft.change(photos[0], routeAt: 150)
        #expect(draft.captions.sorted() == ["Lake", "New one"])
        #expect(draft.invalid == nil)
        draft.changeNew("n1") { $0.caption = String(repeating: "a", count: PhotoDraft.maxCaption + 1) }
        #expect(draft.invalid == .captionTooLong)
    }

    @Test func theOverlayMovesAddsAndHidesMarkers() {
        let items = PhotoMarkers.items(photos, mapHidden: [], overlay: PhotoMarkerOverlay(
            upserts: [PhotoMarkerItem(id: "p1", lon: 5, lat: 5, caption: nil, thumbPath: "/t/p1"), PhotoMarkerItem(id: "n1", lon: 6, lat: 6, caption: nil, thumbPath: "local:n1")],
            hidden: ["p2"], activeID: "n1"
        ))
        #expect(items.map(\.id) == ["p1", "n1"])
        #expect(items[0].lon == 5)
    }
}

/// What a picked photo's EXIF says (root docs/SPEC.md FR-16.1), Android's PhotoExifFieldsTest.
struct PhotoExifFieldsTests {
    private func resolve(original: String? = nil, dateTime: String? = nil, offset: String? = nil, lat: Double? = nil, lon: Double? = nil,
                         gpsDate: String? = nil, gpsTime: String? = nil) -> PhotoExif {
        PhotoExifFields.resolve(dateTimeOriginal: original, dateTime: dateTime, offsetTimeOriginal: offset, lat: lat, lon: lon, gpsDate: gpsDate, gpsTime: gpsTime)
    }

    private func at(_ iso: String) -> Date { ISOMoment.parse(iso)! }

    @Test func aZonedCaptureTimeIsAnInstant() {
        let exif = resolve(original: "2026:09:30 13:00:20", offset: "-04:00")
        #expect(exif.takenAt == at("2026-09-30T17:00:20Z"))
        #expect(exif.takenLocal == nil)
    }

    @Test func theGpsClockGivesTheZoneAndTheCameraKeepsItsSeconds() {
        // The camera says 13:00:20; the fix, a little stale, 17:01:05 UTC: four hours behind, to
        // the nearest quarter hour, so the camera's own clock read at -04:00.
        #expect(resolve(original: "2026:09:30 13:00:20", gpsDate: "2026:09:30", gpsTime: "17:01:05").takenAt == at("2026-09-30T17:00:20Z"))
    }

    @Test func theGpsClockReadsAsRationalsToo() {
        #expect(resolve(original: "2026:09:30 13:00:20", gpsDate: "2026:09:30", gpsTime: "17/1,0/1,30/1").takenAt == at("2026-09-30T17:00:20Z"))
    }

    @Test func aZoneOutsideTheWorldsFallsBackToTheGpsTime() {
        #expect(resolve(original: "2026:09:30 13:00:20", gpsDate: "2026:09:28", gpsTime: "17:00:00").takenAt == at("2026-09-28T17:00:00Z"))
    }

    @Test func withNoZoneTheTimeGoesAsAWallClock() {
        let exif = resolve(original: "2026:09:30 13:00:00")
        #expect(exif.takenAt == nil)
        #expect(exif.takenLocal == "2026-09-30T13:00:00")
    }

    @Test func theFilesDateTimeStandsInForAMissingOriginal() {
        #expect(resolve(dateTime: "2026:09:30 08:15:42").takenLocal == "2026-09-30T08:15:42")
    }

    @Test func onlyAGpsClockIsStillACaptureTime() {
        #expect(resolve(gpsDate: "2026:09:30", gpsTime: "17:00:00").takenAt == at("2026-09-30T17:00:00Z"))
    }

    @Test func blankValuesReadAsAbsent() {
        let exif = resolve(original: "0000:00:00 00:00:00", dateTime: "    :  :     :  :  ", lat: 0, lon: 0)
        #expect(exif == PhotoExif())
    }

    @Test func aPositionIsKeptWhenItsReal() {
        let exif = resolve(lat: 41.482, lon: -81.703)
        #expect(exif.lat == 41.482)
        #expect(exif.lon == -81.703)
        #expect(resolve(lat: 95, lon: 10).lat == nil)
    }
}
