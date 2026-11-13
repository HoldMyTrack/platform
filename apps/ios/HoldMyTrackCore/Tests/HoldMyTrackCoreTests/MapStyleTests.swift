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
     "tiers": [{"tier": "country", "below": 4}, {"tier": "region", "below": 8}, {"tier": "city"}],
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
        "layers": [{"id": "track-bands-line", "type": "line", "source": "track-bands"}],
        "legend": {"band-10": {"color": "#c00"}, "band-0": {"color": "#00b"}, "band-2": {"color": "#0b0"}, "other": {"color": "#fff"}}},
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

    @Test func aViewNamedForNoModeIsNeverApplied() {
        // The server keeps a `heatmap` view and layer for old Android builds.
        let stub = LayersDocument(JSONValue.parse(Data("""
        {"views": {"plain": {
           "normal": {"layout": {"heat": {"visibility": "none"}}},
           "fog": {"layout": {"heat": {"visibility": "none"}}},
           "heatmap": {"layout": {"heat": {"visibility": "visible"}}, "paint": {"earth": {"fill-opacity": 0.3}}}}},
         "groups": [{"id": "coverage", "sources": {}, "layers": [{"id": "heat", "type": "heatmap"}]}]}
        """.utf8))!)!
        for mode in MapMode.allCases {
            var state = MapState()
            state.mode = mode
            let composed = MapStyle.compose(style: style, document: stub, state: state, apiBase: api)
            #expect(layer(composed, "heat")?["layout"]?["visibility"] == .string("none"), "\(mode)")
            #expect(layer(composed, "earth")?["paint"] == nil, "\(mode)")
        }
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

    @Test func failedImageryDrawsAsSatelliteOffWithItsLayerKept() {
        var state = MapState()
        state.satellite = true
        state.satelliteFailed = true
        let failed = compose(state)
        #expect(layer(failed, "satellite")?["layout"]?["visibility"] == .string("visible"), "a tile arriving later is noticed")
        #expect(layer(failed, "earth")?["layout"]?["visibility"] == .string("visible"))
        #expect(layer(failed, "roads_major")?["paint"]?["line-opacity"] == .number(1))
        #expect(layer(failed, "tracks-line")?["paint"]?["line-color"] == nil, "the plain view applies")
    }

    @Test func theTierInViewIsTheFirstWhoseBelowIsPastTheZoom() {
        #expect(ZoomTier.at(0, tiers: document.tiers) == .country)
        #expect(ZoomTier.at(3.99, tiers: document.tiers) == .country)
        #expect(ZoomTier.at(4, tiers: document.tiers) == .region)
        #expect(ZoomTier.at(8, tiers: document.tiers) == .city)
        #expect(ZoomTier.at(3, tiers: []) == .city, "a document without tiers draws exact coverage")
    }

    @Test func fogHasAChipAndALevelNormalHasNeither() {
        #expect(MapChrome.chip(.normal) == nil)
        #expect(MapChrome.chip(.fog) == .everyActivity)
        #expect(MapChrome.level(.normal, tier: .city) == nil)
        #expect(MapChrome.level(.fog, tier: .country) == .fogCountry)
        #expect(MapChrome.level(.fog, tier: .region) == .fogRegion)
        #expect(MapChrome.level(.fog, tier: .city) == .fogCity)
    }

    @Test func theLayersBadgeCountsRoadsAndPathsAndGreysWhileHidden() {
        var state = MapState()
        #expect(MapChrome.layersBadge(state, places: 0) == .init(count: 1, filled: true, greyed: false), "Roads starts picked")
        state.roads = false
        #expect(MapChrome.layersBadge(state, places: 0) == .init(count: 0, filled: false, greyed: false))
        state.toggles = ["bikePaths": true, "sharedPaths": false, "mtbTrails": true]
        #expect(MapChrome.layersBadge(state, places: 0).count == 2)
        state.showLayers = false
        #expect(MapChrome.layersBadge(state, places: 0) == .init(count: 2, filled: false, greyed: true))
        state.showLayers = true
        state.toggles[Spots.group] = true
        #expect(MapChrome.layersBadge(state, places: 3).count == 5, "each place category counts, not the group's switch")
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

    @Test func cssColorsParseToComponents() {
        #expect(CSSColor("#000000") == CSSColor(0, 0, 0, 1))
        #expect(CSSColor("#fff") == CSSColor(1, 1, 1, 1))
        #expect(CSSColor("#FF000080") == CSSColor(1, 0, 0, 128.0 / 255))
        #expect(CSSColor("rgb(255, 0, 51)") == CSSColor(1, 0, 0.2, 1))
        #expect(CSSColor("rgba(0,0,0,0.5)") == CSSColor(0, 0, 0, 0.5))
        #expect(CSSColor("hsl(0, 0%, 0%)") == nil, "an unknown form reloads the style")
        #expect(CSSColor("#12345") == nil)
        #expect(CSSColor("rgb(1, 2)") == nil)
    }

    @Test func noChangeIsAnEmptyList() {
        #expect(MapStyle.changes(from: compose(), to: compose()) == [])
    }

    @Test func newGeoJSONDataIsADataChangeNotAReload() throws {
        var state = MapState()
        let empty = compose(state)
        let bands = PaceBands.features(metrics)
        state.geojson[PaceBands.group] = bands
        let drawn = compose(state)
        #expect(drawn["sources"]?["track-bands"]?["data"] == bands)
        #expect(try #require(MapStyle.changes(from: empty, to: drawn)) == [MapStyle.Change(layer: "track-bands", kind: "data", name: "data", value: bands)])
    }

    // MARK: Pace bands

    private let metrics = TrackMetrics(
        activityID: "a1",
        points: [.init(lon: 0, lat: 0), .init(lon: 1, lat: 0), .init(lon: 2, lat: 0), .init(lon: 3, lat: 0)],
        bands: [.init(band: 0, start: 0, end: 2), .init(band: 4, start: 2, end: 3)]
    )

    @Test func eachRunIsALineWithItsBandAndTheRouteIsOneMore() {
        let features = PaceBands.features(metrics)["features"]?.array ?? []
        #expect(features.count == 3)
        #expect(features[0]["properties"]?["band"] == .number(0))
        #expect(features[0]["geometry"]?["coordinates"]?.array?.count == 3)
        #expect(features[1]["properties"]?["band"] == .number(4))
        #expect(features[1]["geometry"]?["coordinates"]?.array?.first == .array([.number(2), .number(0)]), "runs share their boundary point")
        #expect(features[2]["properties"]?["route"] == .bool(true))
        #expect(features[2]["geometry"]?["coordinates"]?.array?.count == 4)
        #expect(PaceBands.features(nil)["features"] == .array([]))
    }

    @Test func aRunPastThePointsIsSkipped() {
        let broken = TrackMetrics(activityID: "a1", points: metrics.points, bands: [.init(band: 1, start: 2, end: 9)])
        #expect(PaceBands.features(broken)["features"]?.array?.count == 1, "the route alone")
    }

    @Test func bandsAreDrawnOnlyForTheFocusedActivityWhileItsTrackIs() {
        #expect(PaceBands.drawn(metrics, focused: "a1", mapHidden: []) == metrics)
        #expect(PaceBands.drawn(metrics, focused: "a2", mapHidden: []) == nil, "a new focus's are still loading")
        #expect(PaceBands.drawn(metrics, focused: nil, mapHidden: []) == nil)
        #expect(PaceBands.drawn(metrics, focused: "a1", mapHidden: ["a1"]) == nil)
        #expect(PaceBands.drawn(nil, focused: "a1", mapHidden: []) == nil)
    }

    @Test func theLegendIsTheGroupsBandsInOrder() {
        #expect(PaceBands.colors(document) == ["#00b", "#0b0", "#c00"])
    }
}

/// Where the map first frames an account (apps/android/docs/SPEC.md FR-2.3).
struct MapFramingTests {



}
