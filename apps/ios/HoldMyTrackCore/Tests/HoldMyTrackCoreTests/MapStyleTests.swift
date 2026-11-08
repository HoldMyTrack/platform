import Foundation
import Testing

@testable import HoldMyTrackCore

/// The basemap style and the layers document combined into the one style the map loads, and the
/// changes between two of them (apps/ios/docs/IMPLEMENTATION.md §3.1).
struct MapStyleTests {
    private let api = URL(string: "http://localhost:8081")!

    /// A basemap: ground, two trails a group lifts, roads, the satellite layer, and labels.
    private let style = JSONValue.parse(Data("""
    {"version": 8,
     "metadata": {"holdmytrack:style-build": "b1", "holdmytrack:roads": ["roads_major"],
                  "holdmytrack:satellite-hides": ["earth"], "holdmytrack:satellite-dims": ["roads_major"],
                  "holdmytrack:satellite-road-opacity": 0.4},
     "sources": {"protomaps": {"type": "vector"}, "satellite": {"type": "raster"}},
     "layers": [
       {"id": "background", "type": "background"},
       {"id": "satellite", "type": "raster", "source": "satellite", "layout": {"visibility": "none"}},
       {"id": "earth", "type": "fill", "source": "protomaps"},
       {"id": "paths_trail", "type": "line", "source": "protomaps"},
       {"id": "roads_major", "type": "line", "source": "protomaps"},
       {"id": "place_label", "type": "symbol", "source": "protomaps"},
       {"id": "country_label", "type": "symbol", "source": "protomaps"}
     ]}
    """.utf8))!

    private let document = LayersDocument(JSONValue.parse(Data("""
    {"styleBuild": "b1", "tileVersion": "7.1",
     "vars": {"hidden": []},
     "views": {
       "plain": {
         "normal": {"layout": {"fog-veil": {"visibility": "none"}, "tracks-line": {"visibility": "visible"}}},
         "fog": {"layout": {"fog-veil": {"visibility": "visible"}, "tracks-line": {"visibility": "visible"}},
                 "paint": {"place_label": {"text-opacity": 0.5}, "tracks-line": {"line-opacity": 0.6}}}
       },
       "satellite": {
         "normal": {"layout": {"fog-veil": {"visibility": "none"}}, "paint": {"tracks-line": {"line-color": "#ffffff"}}}
       }
     },
     "groups": [
       {"id": "coverage", "placement": "beneath-labels",
        "sources": {"fog-vector": {"type": "vector", "tiles": "/tiles/v1/fog-vector/{z}/{x}/{y}.mvt?cv=7.1", "maxzoom": 14}},
        "layers": [{"id": "fog-veil", "type": "fill", "source": "fog-vector", "layout": {"visibility": "none"}}]},
       {"id": "bike-paths", "placement": "beneath-labels", "lifts": ["paths_trail"],
        "sources": {"bike-paths": {"type": "vector", "tiles": "/tiles/v1/bike-paths/{z}/{x}/{y}.mvt?cv=7.1"}},
        "layers": [{"id": "bike-paths-cycleway", "type": "line", "source": "bike-paths",
                    "metadata": {"holdmytrack:toggle": "bikePaths"}}]},
       {"id": "tracks", "placement": "beneath-labels",
        "sources": {"tracks": {"type": "vector", "tiles": "/tiles/v1/tracks/{z}/{x}/{y}.mvt?cv=7.1"}},
        "layers": [{"id": "tracks-line", "type": "line", "source": "tracks",
                    "filter": ["!", ["in", ["get", "id"], ["var", "hidden"]]],
                    "metadata": {"holdmytrack:vars": {"filter": ["hidden"]}, "holdmytrack:role": "track"}}]},
       {"id": "track-bands", "placement": "beneath-labels",
        "sources": {"track-bands": {"type": "geojson"}},
        "layers": [{"id": "track-bands-line", "type": "line", "source": "track-bands"}]},
       {"id": "spots", "placement": "top",
        "sources": {"spots": {"type": "vector", "tiles": "/tiles/v1/spots/{z}/{x}/{y}.mvt?cv=7.1"}},
        "layers": [{"id": "spots-icons", "type": "symbol", "source": "spots"}]}
     ]}
    """.utf8))!)!

    private func compose(_ state: MapState = MapState()) -> JSONValue {
        MapStyle.compose(style: style, document: document, state: state, apiBase: api)
    }

    private func ids(_ composed: JSONValue) -> [String] {
        composed["layers"]?.array?.compactMap { $0["id"]?.string } ?? []
    }

    private func layer(_ composed: JSONValue, _ id: String) -> JSONValue? {
        composed["layers"]?.array?.first { $0["id"]?.string == id }
    }

    @Test func ownLayersGoBeneathTheLabelsWithLiftedTrailsAboveCoverageAndTopGroupsLast() {
        #expect(ids(compose()) == [
            "background", "satellite", "earth", "roads_major",
            "fog-veil", "paths_trail", "bike-paths-cycleway", "tracks-line", "track-bands-line",
            "place_label", "country_label", "spots-icons",
        ])
    }

    @Test func anExcludedGroupIsLeftOutWithItsSources() {
        var state = MapState()
        state.excludedGroups = ["spots"]
        let composed = compose(state)
        #expect(!ids(composed).contains("spots-icons"))
        #expect(composed["sources"]?["spots"] == nil)
    }

    @Test func vectorTilesAreOnTheAPIWithTheirQueryAndGeoJSONStartsEmpty() {
        var state = MapState()
        state.queries = ["tracks": "from=2026-10-01&to=2026-10-16"]
        let sources = compose(state)["sources"]
        #expect(sources?["tracks"]?["tiles"] == .array([.string("http://localhost:8081/tiles/v1/tracks/{z}/{x}/{y}.mvt?cv=7.1&from=2026-10-01&to=2026-10-16")]))
        #expect(sources?["fog-vector"]?["tiles"] == .array([.string("http://localhost:8081/tiles/v1/fog-vector/{z}/{x}/{y}.mvt?cv=7.1")]))
        #expect(sources?["track-bands"]?["data"]?["type"] == .string("FeatureCollection"))
        #expect(sources?["protomaps"] == .object(["type": .string("vector")]))
    }

    @Test func theModesViewSetsOwnAndBasemapLayers() {
        var state = MapState()
        #expect(layer(compose(state), "fog-veil")?["layout"]?["visibility"] == .string("none"))
        state.mode = .fog
        let fog = compose(state)
        #expect(layer(fog, "fog-veil")?["layout"]?["visibility"] == .string("visible"))
        #expect(layer(fog, "tracks-line")?["paint"]?["line-opacity"] == .number(0.6))
        #expect(layer(fog, "place_label")?["paint"]?["text-opacity"] == .number(0.5))
    }

    @Test func aLayerTheViewDoesntNameIsShownOnceAViewApplies() {
        // As on Android: what a layer is added with holds only until a view applies.
        #expect(layer(compose(), "track-bands-line")?["layout"]?["visibility"] == .string("visible"))
    }

    @Test func aSwitchedLayerShowsOnlyWithItsSwitchAndShowLayersOn() {
        var state = MapState()
        #expect(layer(compose(state), "bike-paths-cycleway")?["layout"]?["visibility"] == .string("none"))
        state.toggles = ["bikePaths": true]
        #expect(layer(compose(state), "bike-paths-cycleway")?["layout"]?["visibility"] == .string("visible"))
        state.showLayers = false
        #expect(layer(compose(state), "bike-paths-cycleway")?["layout"]?["visibility"] == .string("none"))
    }

    @Test func aHiddenGroupIsDrawnHidden() {
        var state = MapState()
        state.hiddenGroups = ["tracks"]
        #expect(layer(compose(state), "tracks-line")?["layout"]?["visibility"] == .string("none"))
    }

    @Test func varsAreBoundAsALetWithArraysAsLiterals() {
        let filter = ["!", ["in", ["get", "id"], ["var", "hidden"]]] as [Any]
        var state = MapState()
        #expect(layer(compose(state), "tracks-line")?["filter"]?.foundation as? NSArray
            == (["let", "hidden", ["literal", []], filter] as NSArray))
        state.vars = ["hidden": .array([.string("a1")])]
        #expect(layer(compose(state), "tracks-line")?["filter"]?.foundation as? NSArray
            == (["let", "hidden", ["literal", ["a1"]], filter] as NSArray))
    }

    @Test func theAppsMetadataStaysOutOfTheStyle() {
        #expect(layer(compose(), "tracks-line")?["metadata"] == nil)
    }

    @Test func satelliteShowsTheImageryHidesTheFillsAndDimsTheRoads() {
        var state = MapState()
        let plain = compose(state)
        #expect(layer(plain, "satellite")?["layout"]?["visibility"] == .string("none"))
        #expect(layer(plain, "earth")?["layout"]?["visibility"] == .string("visible"))
        #expect(layer(plain, "roads_major")?["paint"]?["line-opacity"] == .number(1))
        state.satellite = true
        let imagery = compose(state)
        #expect(layer(imagery, "satellite")?["layout"]?["visibility"] == .string("visible"))
        #expect(layer(imagery, "earth")?["layout"]?["visibility"] == .string("none"))
        #expect(layer(imagery, "roads_major")?["paint"]?["line-opacity"] == .number(0.4))
        #expect(layer(imagery, "tracks-line")?["paint"]?["line-color"] == .string("#ffffff"), "the satellite view applies")
    }

    @Test func roadsShowWhilePickedAndShowLayersIsOn() {
        var state = MapState()
        #expect(layer(compose(state), "roads_major")?["layout"]?["visibility"] == .string("visible"))
        state.roads = false
        #expect(layer(compose(state), "roads_major")?["layout"]?["visibility"] == .string("none"))
        state.roads = true
        state.showLayers = false
        #expect(layer(compose(state), "roads_major")?["layout"]?["visibility"] == .string("none"))
    }

    @Test func theStylesBuildIsReadFromItsMetadata() {
        #expect(MapStyle.build(ofStyle: style) == "b1")
        #expect(MapStyle.hasSatellite(style))
    }

    // MARK: Changes

    @Test func aModeSwitchIsPropertiesOnly() throws {
        var state = MapState()
        let normal = compose(state)
        state.mode = .fog
        let changes = try #require(MapStyle.changes(from: normal, to: compose(state)))
        #expect(changes.contains(MapStyle.Change(layer: "fog-veil", kind: "layout", name: "visibility", value: .string("visible"))))
        #expect(changes.contains(MapStyle.Change(layer: "place_label", kind: "paint", name: "text-opacity", value: .number(0.5))))
        #expect(!changes.contains { $0.layer == "earth" })
    }

    @Test func aNewVarIsAFilterChange() throws {
        var state = MapState()
        let before = compose(state)
        state.vars = ["hidden": .array([.string("a1")])]
        let changes = try #require(MapStyle.changes(from: before, to: compose(state)))
        #expect(changes.map(\.layer) == ["tracks-line"])
        #expect(changes.first?.kind == "filter")
    }

    @Test func aNewTileQueryNeedsAReload() {
        var state = MapState()
        let before = compose(state)
        state.queries = ["tracks": "from=2026-10-01&to=2026-10-02"]
        #expect(MapStyle.changes(from: before, to: compose(state)) == nil)
    }

    @Test func aPropertyTheNewStyleDropsIsUnset() throws {
        var state = MapState()
        state.mode = .fog
        let fog = compose(state)
        state.mode = .normal
        let changes = try #require(MapStyle.changes(from: fog, to: compose(state)))
        #expect(changes.contains(MapStyle.Change(layer: "place_label", kind: "paint", name: "text-opacity", value: nil)))
    }

    @Test func noChangeIsAnEmptyList() {
        #expect(MapStyle.changes(from: compose(), to: compose()) == [])
    }
}

/// Where the map first frames an account (apps/android/docs/SPEC.md FR-2.3).
struct MapFramingTests {
    private func row(_ id: String, _ t: TimeInterval?, bbox: [Double]? = [0, 0, 1, 1], pending: Bool = false) -> ActivityRow {
        ActivityRow(id: id, startedAt: t.map { Date(timeIntervalSince1970: $0) }, bbox: bbox.map { $0.map { $0 + Double(id.count) } }, pending: pending)
    }

    @Test func theMostRecentActivityWithATrackIsFramed() {
        let rows = [row("a", 100), row("bb", 300), row("ccc", 200)]
        #expect(MapFraming.latest(rows) == [2, 2, 3, 3])
    }

    @Test func pendingAndTracklessActivitiesAreSkipped() {
        let rows = [row("a", 100), row("bb", 300, pending: true), row("ccc", 400, bbox: nil)]
        #expect(MapFraming.latest(rows) == [1, 1, 2, 2])
    }

    @Test func anAccountWithNothingOnTheMapHasNoFrame() {
        #expect(MapFraming.latest([]) == nil)
        #expect(MapFraming.latest([row("a", 100, bbox: nil)]) == nil)
    }
}
