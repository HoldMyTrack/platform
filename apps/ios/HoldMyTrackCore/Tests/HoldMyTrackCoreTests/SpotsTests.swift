import Foundation
import Testing

@testable import HoldMyTrackCore

/// Spots on the map (apps/android/docs/SPEC.md FR-2.8), what the app decides of them.
struct SpotsTests {
    private let document = LayersDocument(JSONValue.parse(Data("""
    {"views": {}, "groups": [
      {"id": "spots", "placement": "top", "sources": {},
       "layers": [
         {"id": "spots-in-area-icons", "type": "symbol", "source": "spots-in-area", "minzoom": 10, "maxzoom": 13,
          "metadata": {"holdmytrack:images": {"spot-dog_park": {"category": "dog_park", "fill": "#fff", "ring": "#0a0", "ink": "#000"},
                                              "spot-ufo": {"category": "ufo", "fill": "#fff", "ring": "#fff", "ink": "#fff"}}}},
         {"id": "spots-icons", "type": "symbol", "source": "spots",
          "metadata": {"holdmytrack:images": {"spot-dog_park-captured": {"category": "dog_park", "fill": "#0a0", "ring": "#fff", "ink": "#fff"}}}}
       ]}
    ]}
    """.utf8))!)!

    @Test func theGroupsSwitchAndVarsFollowThePicksTheCapturesAndTheTarget() {
        var state = MapState()
        Spots.apply(categories: [], captured: [:], target: nil, to: &state)
        #expect(state.toggles["spots"] == false)
        #expect(state.vars["captureTarget"] == .number(-1))
        Spots.apply(categories: [.dogPark, .history], captured: [9: Date(), 3: Date()], target: 3, to: &state)
        #expect(state.toggles["spots"] == true)
        #expect(state.vars["spotCategories"] == .array([.string("dog_park"), .string("history")]))
        #expect(state.vars["captured"] == .array([.number(3), .number(9)]))
        #expect(state.vars["captureTarget"] == .number(3))
    }

    @Test func badgesAreEveryImageTheLayersNameOfAKnownCategory() {
        let badges = Spots.badges(document)
        #expect(Set(badges.keys) == ["spot-dog_park", "spot-dog_park-captured"])
        #expect(badges["spot-dog_park-captured"] == SpotBadge(category: .dogPark, fill: "#0a0", ring: "#fff", ink: "#fff"))
    }

    @Test func showInThisAreaWorksBetweenItsLayersZooms() {
        let zooms = Spots.inAreaZooms(document)
        #expect(zooms == 10..<13)
        let area = ShowInArea()
        #expect(area.label(categories: [.monument], zoom: 9.9, zooms: zooms) == nil)
        #expect(area.label(categories: [.monument], zoom: 10, zooms: zooms) == .offer)
        #expect(area.label(categories: [.monument], zoom: 13, zooms: zooms) == nil, "the tiles take over")
        #expect(area.label(categories: [], zoom: 11, zooms: zooms) == nil)
    }

    @Test func aCurrentLoadSaysWhatItFound() {
        var area = ShowInArea()
        let zooms = 10.0..<13.0
        area.started()
        #expect(area.label(categories: [.monument], zoom: 11, zooms: zooms) == .loading)
        area.finished(categories: [.monument, .history], shown: 200, total: 340)
        #expect(area.label(categories: [.monument], zoom: 11, zooms: zooms) == .truncated(shown: 200, total: 340))
        #expect(area.label(categories: [.monument, .waterfall], zoom: 11, zooms: zooms) == .offer, "a category picked since")
        area.cameraMoved()
        #expect(area.label(categories: [.monument], zoom: 11, zooms: zooms) == .offer)
        area.started()
        area.finished(categories: [.monument], shown: 4, total: 4)
        #expect(area.label(categories: [.monument], zoom: 11, zooms: zooms) == .count(4))
        area.started()
        area.finished(categories: [.monument], shown: 0, total: 0)
        #expect(area.label(categories: [.monument], zoom: 11, zooms: zooms) == ShowInArea.Label.none)
        area.started()
        area.failedLoading()
        #expect(area.label(categories: [.monument], zoom: 11, zooms: zooms) == .failed)
    }

    @Test func aPlaceComesBackFromItsBadgesAttributes() {
        let spot = Spot(id: 42, category: "monument", name: "Soldiers", startDate: "1901", lon: -81.5, lat: 41.2)
        let properties = Spots.inAreaFeatures([spot])["features"]?.array?.first?["properties"]?.object ?? [:]
        let attributes = properties.mapValues { value -> Any in value.number.map { NSNumber(value: $0) } ?? value.string ?? "" }
        #expect(Spot(attributes: attributes) == spot)
        #expect(Spot(attributes: ["category": "monument"]) == nil)
        #expect(Spot(attributes: ["id": NSNumber(value: 1), "category": "monument", "lon": NSNumber(value: 0), "lat": NSNumber(value: 0), "name": ""])?.name == nil)
    }

    @Test func aViewAcrossTheAntimeridianSwapsItsEdges() {
        #expect(Spots.viewEdges(west: 10, east: 20) == (10, 20))
        #expect(Spots.viewEdges(west: -179, east: 179) == (179, 181))
    }

    @Test func capturesAreAskedForSinceTheNewestAndMerged() {
        let old = Date(timeIntervalSince1970: 100), new = Date(timeIntervalSince1970: 200)
        #expect(Spots.capturesSince([:]) == nil)
        #expect(Spots.capturesSince([1: old, 2: new]) == new)
        #expect(Spots.merge([1: old, 2: new], [2: new, 3: new]) == [1: old, 2: new, 3: new])
    }

    @Test func thePopupsText() {
        #expect(Spots.address(Spot(id: 1, category: "monument", address: "1 Main St", lon: 0, lat: 0)) == "1 Main St")
        #expect(Spots.address(Spot(id: 1, category: "monument", lon: -81.5, lat: 41.25)) == "41.250000, -81.500000")
        #expect(Spots.wikipediaURL("en:Soldiers' Monument (Ohio)")?.absoluteString == "https://en.wikipedia.org/wiki/Soldiers'_Monument_(Ohio)")
        #expect(Spots.wikipediaURL("ru:Дом")?.absoluteString == "https://ru.wikipedia.org/wiki/%D0%94%D0%BE%D0%BC")
        #expect(Spots.wikipediaURL("no language") == nil)
        #expect(Spots.memorialLabel("war_memorial") == "War memorial")
        #expect(Spots.memorialLabel("plaque;stone") == "Plaque stone")
    }
}
