import Foundation
import Testing

@testable import HoldMyTrackCore

struct PhotoTests {
    @Test func noScopeShowsNoMarkers() {
        #expect(!PhotoMarkers.shown(nil, mapHidden: []))
    }

    @Test func anActivitysMarkersHideWithItsRoute() {
        #expect(PhotoMarkers.shown(.activity("a"), mapHidden: ["b"]))
        #expect(!PhotoMarkers.shown(.activity("a"), mapHidden: ["a"]))
    }

    @Test func aStorysMarkersShowWhateverIsHidden() {
        #expect(PhotoMarkers.shown(.story("s"), mapHidden: ["a"]))
    }

    @Test func markersLeaveOutUnplacedPhotosAndHiddenRoutes() {
        let photos = [
            Photo(id: "1", activityID: "a", lon: 1, lat: 2, caption: "Lake", thumbURL: "/t/1"),
            Photo(id: "2", activityID: "a"),
            Photo(id: "3", activityID: "b", lon: 3, lat: 4, thumbURL: "/t/3"),
            Photo(id: "4", activityID: "a", lon: 5, lat: 6, thumbURL: "/t/4"),
        ]
        let items = PhotoMarkers.items(photos, mapHidden: ["b"])
        #expect(items == [
            PhotoMarkerItem(id: "1", lon: 1, lat: 2, caption: "Lake", thumbPath: "/t/1"),
            PhotoMarkerItem(id: "4", lon: 5, lat: 6, caption: nil, thumbPath: "/t/4"),
        ])
    }
}
