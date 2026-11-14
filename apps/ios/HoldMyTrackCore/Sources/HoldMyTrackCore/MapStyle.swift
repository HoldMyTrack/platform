import Foundation

/// The layers document, `GET /v1/map/layers` (root docs/ARCHITECTURE.md §2.1, ADR-0048): every
/// layer HoldMyTrack draws over the basemap, each mode's view, and the defaults of the values a
/// layer reads at run time. Defined once in the web's mapLayers.ts; read here, decided nowhere.
public struct LayersDocument: Equatable, Sendable {
    public enum Placement: Equatable, Sendable { case beneathLabels, top }

    public struct Group: Equatable, Sendable {
        public let id: String
        public let placement: Placement
        /// Basemap layers the group lifts above the ones beneath it (trails over Fog).
        public let lifts: [String]
        /// By id, as the document gives them; a vector source's `tiles` is a path on the API.
        public let sources: [String: JSONValue]
        public let layers: [JSONValue]
        /// By entry, the color the Layers menu or a card shows for it.
        public let legend: [String: String]
    }

    public let styleBuild: String
    public let tileVersion: String
    /// Fog's levels, coarsest first, each with its band and layers.
    public let levels: [FogLevels.Level]
    /// By name, the default of each value a layer reads as `["var", name]`.
    public let vars: [String: JSONValue]
    /// `plain` and `satellite`, each by mode, then `layout` or `paint`, then layer id.
    public let views: JSONValue
    public let groups: [Group]

    public init?(_ json: JSONValue) {
        guard let groups = json["groups"]?.array, let views = json["views"] else { return nil }
        styleBuild = json["styleBuild"]?.string ?? ""
        tileVersion = json["tileVersion"]?.string ?? ""
        vars = json["vars"]?.object ?? [:]
        levels = json["levels"]?.array?.compactMap(FogLevels.Level.init) ?? []
        self.views = views
        var parsed: [Group] = []
        for g in groups {
            guard let id = g["id"]?.string, let layers = g["layers"]?.array else { return nil }
            parsed.append(Group(
                id: id,
                placement: g["placement"]?.string == "top" ? .top : .beneathLabels,
                lifts: g["lifts"]?.array?.compactMap(\.string) ?? [],
                sources: g["sources"]?.object ?? [:],
                layers: layers,
                legend: (g["legend"]?.object ?? [:]).compactMapValues { $0["color"]?.string }
            ))
        }
        self.groups = parsed
    }

    /// Each layer id of placement in paint order, the basemap layers groups lift included.
    func order(_ groups: [Group], _ placement: Placement) -> [String] {
        groups.filter { $0.placement == placement }.flatMap { $0.lifts + $0.layers.compactMap { $0["id"]?.string } }
    }
}

/// The mode the map shows for the tab bar's tab (apps/android/docs/SPEC.md FR-2.2): the one picked
/// on the Map tab there, Normal on Stories, whose sheet and tracks are Normal mode's. The toggle is
/// the Map tab's, so back there the pick comes back.
public enum TabMode {
    public static func shown(picked: MapMode, onMapTab: Bool) -> MapMode { onMapTab ? picked : .normal }

    public static func toggleShown(onMapTab: Bool) -> Bool { onMapTab }
}

/// What the app decides about the map; the rest is the documents'.
public struct MapState: Equatable, Sendable {
    public var mode: MapMode = .normal
    /// The Layers menu: Satellite, Roads, Show layers, and the switches layers name
    /// (`holdmytrack:toggle`: bikePaths, sharedPaths, mtbTrails, spots).
    public var satellite = false
    /// The imagery didn't load on this device: the map draws as with Satellite off, its layer
    /// left on to notice a tile (SatelliteStatus).
    public var satelliteFailed = false
    public var roads = true
    public var showLayers = true
    public var toggles: [String: Bool] = [:]
    /// By var name, the value bound in place of the document's default.
    public var vars: [String: JSONValue] = [:]
    /// Groups drawn hidden: the track editor hides the tracks.
    public var hiddenGroups: Set<String> = []
    /// By source id, a query appended to its tiles: the tracks' date range.
    public var queries: [String: String] = [:]
    /// By GeoJSON source id, its data: the pace bands. A source without starts empty.
    public var geojson: [String: JSONValue] = [:]
    /// The Fog level the level control locked, drawn at every zoom; nil follows the zoom.
    public var fogLevel: String?

    public init() {}
}

/// The basemap style and the layers document as the one style MapLibre loads, and what changes
/// between two of them. MapLibre Native can't add a layer from JSON but loads a whole style from
/// it, so the app combines the two here, where it's tested, and only patches properties at run
/// time (apps/ios/docs/IMPLEMENTATION.md §3.1).
public enum MapStyle {
    static let toggleKey = "holdmytrack:toggle"
    static let varsKey = "holdmytrack:vars"
    static let roadsKey = "holdmytrack:roads"
    static let hidesKey = "holdmytrack:satellite-hides"
    static let dimsKey = "holdmytrack:satellite-dims"
    static let roadOpacityKey = "holdmytrack:satellite-road-opacity"
    static let buildKey = "holdmytrack:style-build"
    public static let satelliteID = "satellite"

    /// The style's own build, which the layers document's must match: two from different builds
    /// mean the style is fetched again (ADR-0048).
    public static func build(ofStyle style: JSONValue) -> String? {
        style["metadata"]?[buildKey]?.string
    }

    /// Whether the deployment serves satellite imagery: the server leaves the source out otherwise.
    public static func hasSatellite(_ style: JSONValue) -> Bool {
        style["sources"]?[satelliteID] != nil
    }

    /// The style to load: style with document's groups added where they go, their sources'
    /// tiles on apiBase, and state applied.
    public static func compose(style: JSONValue, document: LayersDocument, state: MapState, apiBase: URL) -> JSONValue {
        guard var root = style.object, var sources = root["sources"]?.object, let base = root["layers"]?.array else { return style }
        let groups = document.groups

        var layers: [String: JSONValue] = [:]
        var ids: [String] = []
        for layer in base {
            guard let id = layer["id"]?.string else { continue }
            layers[id] = layer
            ids.append(id)
        }

        // Paint order, by the same steps the Android app adds them in, so the shared
        // layer-insertion rule decides it alike.
        let own = Set(groups.flatMap { $0.layers.compactMap { $0["id"]?.string } })
        let beneath = document.order(groups, .beneathLabels)
        let top = document.order(groups, .top)
        let labels = base.first { $0["type"]?.string == "symbol" && !own.contains($0["id"]?.string ?? "") }?["id"]?.string
        for group in groups {
            for (id, source) in group.sources where sources[id] == nil {
                sources[id] = tileSource(source, id: id, state: state, apiBase: apiBase)
            }
            for id in group.lifts where ids.contains(id) && MapLayers.needsLift(current: ids, id: id, own: own) {
                ids.removeAll { $0 == id }
                insert(id, before: MapLayers.insertionPoint(current: ids, order: beneath, id: id, own: own, fallback: labels), into: &ids)
            }
            let isTop = group.placement == .top
            for layer in group.layers {
                guard let id = layer["id"]?.string, layers[id] == nil else { continue }
                layers[id] = stripped(layer)
                insert(id, before: MapLayers.insertionPoint(current: ids, order: isTop ? top : beneath, id: id, own: own, fallback: isTop ? nil : labels), into: &ids)
            }
        }

        apply(state, document: document, groups: groups, metadata: style["metadata"], hasSatellite: sources[satelliteID] != nil, to: &layers)
        for (id, range) in FogLevels.zoomRanges(document.levels, locked: state.fogLevel) {
            guard var layer = layers[id]?.object else { continue }
            layer["minzoom"] = .number(range.lowerBound)
            layer["maxzoom"] = .number(range.upperBound)
            layers[id] = .object(layer)
        }
        root["sources"] = .object(sources)
        root["layers"] = .array(ids.compactMap { layers[$0] })
        return .object(root)
    }

    // MARK: Applying the state

    private static func apply(_ state: MapState, document: LayersDocument, groups: [LayersDocument.Group], metadata: JSONValue?, hasSatellite: Bool, to layers: inout [String: JSONValue]) {
        let look = hasSatellite && SatelliteStatus.look(on: state.satellite, status: state.satelliteFailed ? .failed : .loading)
        let view = document.views[look ? "satellite" : "plain"]?[state.mode.rawValue]
        let specs = Dictionary(groups.flatMap { g in g.layers.compactMap { l in l["id"]?.string.map { ($0, (l, g)) } } }, uniquingKeysWith: { a, _ in a })

        // The basemap's own layers a view sets.
        for kind in ["layout", "paint"] {
            for (id, props) in view?[kind]?.object ?? [:] where specs[id] == nil {
                for (name, value) in props.object ?? [:] { set(&layers, id, kind, name, value) }
            }
        }

        for (id, (spec, group)) in specs {
            guard layers[id] != nil else { continue }
            for kind in ["layout", "paint"] {
                for (name, value) in view?[kind]?[id]?.object ?? [:] where name != "visibility" {
                    set(&layers, id, kind, name, value)
                }
            }
            // What a layer is added with holds until a view applies; from then the view, the
            // switch and the hidden groups decide, as on Android.
            let base = (view?["layout"]?[id]?["visibility"]?.string ?? "visible") == "visible"
            let toggle = spec["metadata"]?[toggleKey]?.string
            let switched = toggle.map { state.showLayers && state.toggles[$0] == true } ?? true
            let shown = base && switched && !state.hiddenGroups.contains(group.id)
            set(&layers, id, "layout", "visibility", .string(shown ? "visible" : "none"))

            for (name, names) in spec["metadata"]?[varsKey]?.object ?? [:] {
                let vars = names.array?.compactMap(\.string) ?? []
                if name == "filter" {
                    if let filter = spec["filter"] { setFilter(&layers, id, bind(filter, vars, state.vars, document.vars)) }
                } else {
                    for kind in ["layout", "paint"] {
                        if let value = spec[kind]?[name] { set(&layers, id, kind, name, bind(value, vars, state.vars, document.vars)) }
                    }
                }
            }
        }

        // Satellite (root docs/SPEC.md FR-4.10): the imagery, the basemap's fills hidden over it
        // and its roads see-through; all three lists come from the style's own metadata.
        if hasSatellite {
            set(&layers, satelliteID, "layout", "visibility", .string(state.satellite ? "visible" : "none"))
            for id in metadata?[hidesKey]?.array?.compactMap(\.string) ?? [] {
                set(&layers, id, "layout", "visibility", .string(look ? "none" : "visible"))
            }
            let opacity = look ? (metadata?[roadOpacityKey]?.number ?? 1) : 1
            for id in metadata?[dimsKey]?.array?.compactMap(\.string) ?? [] {
                set(&layers, id, "paint", "line-opacity", .number(opacity))
            }
        }

        // Roads (root docs/SPEC.md FR-4.13), drawn while picked and Show layers is on.
        let roads = state.roads && state.showLayers
        for id in metadata?[roadsKey]?.array?.compactMap(\.string) ?? [] {
            set(&layers, id, "layout", "visibility", .string(roads ? "visible" : "none"))
        }
    }

    /// value with each of names bound to the app's vars, or the document's defaults, as a `let`
    /// around it; an array is bound as a literal.
    static func bind(_ value: JSONValue, _ names: [String], _ vars: [String: JSONValue], _ defaults: [String: JSONValue]) -> JSONValue {
        guard !names.isEmpty else { return value }
        var out: [JSONValue] = [.string("let")]
        for name in names {
            let bound = vars[name] ?? defaults[name] ?? .null
            out.append(.string(name))
            if case .array = bound { out.append(.array([.string("literal"), bound])) } else { out.append(bound) }
        }
        out.append(value)
        return .array(out)
    }

    private static func tileSource(_ source: JSONValue, id: String, state: MapState, apiBase: URL) -> JSONValue {
        guard var s = source.object else { return source }
        if let path = s["tiles"]?.string {
            var url = apiBase.absoluteString + path
            if let query = state.queries[id], !query.isEmpty { url += (url.contains("?") ? "&" : "?") + query }
            s["tiles"] = .array([.string(url)])
        } else if s["type"]?.string == "geojson", s["data"] == nil {
            s["data"] = state.geojson[id] ?? .object(["type": .string("FeatureCollection"), "features": .array([])])
        }
        return .object(s)
    }

    /// A layer as MapLibre takes it: the app's own metadata stays out of the style.
    private static func stripped(_ layer: JSONValue) -> JSONValue {
        guard var l = layer.object else { return layer }
        l["metadata"] = nil
        return .object(l)
    }

    private static func insert(_ id: String, before: String?, into ids: inout [String]) {
        if let before, let at = ids.firstIndex(of: before) { ids.insert(id, at: at) } else { ids.append(id) }
    }

    private static func set(_ layers: inout [String: JSONValue], _ id: String, _ kind: String, _ name: String, _ value: JSONValue) {
        guard var layer = layers[id]?.object else { return }
        var props = layer[kind]?.object ?? [:]
        props[name] = value
        layer[kind] = .object(props)
        layers[id] = .object(layer)
    }

    private static func setFilter(_ layers: inout [String: JSONValue], _ id: String, _ filter: JSONValue) {
        guard var layer = layers[id]?.object else { return }
        layer["filter"] = filter
        layers[id] = .object(layer)
    }

    // MARK: Changes

    /// One property of one layer to set on the loaded map; kind is `layout`, `paint`, `filter` or
    /// `zoom` (name `minzoom` or `maxzoom`, nil for none), or `data` for a GeoJSON source's data,
    /// layer then naming the source.
    public struct Change: Equatable, Sendable {
        public let layer: String
        public let kind: String
        public let name: String
        public let value: JSONValue?
    }

    /// What turns the loaded style old into new: nil when only a reload does (a source other than
    /// a GeoJSON source's data, or the layers or their order, changed), else each GeoJSON source's
    /// new data, then every property and filter to set, in layer order.
    public static func changes(from old: JSONValue, to new: JSONValue) -> [Change]? {
        guard let p = old["sources"]?.object, let q = new["sources"]?.object, Set(p.keys) == Set(q.keys),
              let a = old["layers"]?.array, let b = new["layers"]?.array,
              a.map({ $0["id"] }) == b.map({ $0["id"] })
        else { return nil }
        var out: [Change] = []
        for id in p.keys.sorted() where p[id] != q[id] {
            guard var before = p[id]?.object, var after = q[id]?.object, after["type"]?.string == "geojson" else { return nil }
            let data = after["data"]
            before["data"] = nil
            after["data"] = nil
            guard before == after else { return nil }
            out.append(Change(layer: id, kind: "data", name: "data", value: data))
        }
        for (before, after) in zip(a, b) where before != after {
            guard let id = after["id"]?.string else { continue }
            var keys = Set((before.object ?? [:]).keys).union((after.object ?? [:]).keys)
            keys.subtract(["layout", "paint", "filter", "minzoom", "maxzoom"])
            // Anything but properties, the filter and the zoom range (a source) needs the reload.
            for key in keys where before[key] != after[key] { return nil }
            for name in ["minzoom", "maxzoom"] where before[name] != after[name] {
                out.append(Change(layer: id, kind: "zoom", name: name, value: after[name]))
            }
            for kind in ["layout", "paint"] {
                let p = before[kind]?.object ?? [:], q = after[kind]?.object ?? [:]
                for name in Set(p.keys).union(q.keys).sorted() where p[name] != q[name] {
                    out.append(Change(layer: id, kind: kind, name: name, value: q[name]))
                }
            }
            if before["filter"] != after["filter"] {
                out.append(Change(layer: id, kind: "filter", name: "filter", value: after["filter"]))
            }
        }
        return out
    }
}
