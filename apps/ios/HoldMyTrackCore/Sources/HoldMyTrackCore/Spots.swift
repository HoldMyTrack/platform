import Foundation

/// A place on the Spots layers (root docs/SPEC.md FR-15), from the tiles, "Show in this area" or
/// `GET /v1/spots`.
public struct Spot: Equatable, Sendable {
    public let id: Int
    public let category: String
    public let name: String?
    public let address: String?
    public let description: String?
    public let inscription: String?
    public let memorial: String?
    public let startDate: String?
    public let wikipedia: String?
    public let lon: Double
    public let lat: Double

    public init(id: Int, category: String, name: String? = nil, address: String? = nil, description: String? = nil,
                inscription: String? = nil, memorial: String? = nil, startDate: String? = nil, wikipedia: String? = nil,
                lon: Double, lat: Double) {
        (self.id, self.category, self.name, self.address, self.description) = (id, category, name, address, description)
        (self.inscription, self.memorial, self.startDate, self.wikipedia, self.lon, self.lat) = (inscription, memorial, startDate, wikipedia, lon, lat)
    }

    init(_ json: SpotJSON) {
        self.init(id: json.id, category: json.category, name: json.name, address: json.address, description: json.description,
                  inscription: json.inscription, memorial: json.memorial, startDate: json.startDate, wikipedia: json.wikipedia,
                  lon: json.lon, lat: json.lat)
    }

    /// A badge's feature, as the map hands back its attributes: the tiles' and "Show in this
    /// area"'s carry the same properties (inAreaFeatures). An empty text is none.
    public init?(attributes: [String: Any]) {
        func text(_ key: String) -> String? { (attributes[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func number(_ key: String) -> Double? { (attributes[key] as? NSNumber)?.doubleValue }
        guard let id = number("id"), let category = text("category"), let lon = number("lon"), let lat = number("lat") else { return nil }
        self.init(id: Int(id), category: category, name: text("name"), address: text("address"), description: text("description"),
                  inscription: text("inscription"), memorial: text("memorial"), startDate: text("start_date"),
                  wikipedia: text("wikipedia"), lon: lon, lat: lat)
    }
}

/// The categories, in the order the Layers menu lists them (the web's `SPOT_CATEGORIES`).
public enum SpotCategory: String, CaseIterable, Sendable {
    case playground, dogPark = "dog_park", monument, viewpoint, waterfall, history
}

/// The badge image a symbol layer names: the app draws the category's icon in these colors.
public struct SpotBadge: Equatable, Sendable {
    public let category: SpotCategory
    public let fill: String
    public let ring: String
    public let ink: String
}

/// What the app decides about Spots; what each layer does with it is the layers document's.
public enum Spots {
    public static let group = "spots"
    /// "Show in this area"'s GeoJSON source, and its badges' layer.
    public static let inAreaSource = "spots-in-area"
    public static let inAreaLayer = "spots-in-area-icons"
    /// The layers a tap on a badge can hit.
    public static let badgeLayers = ["spots-icons", inAreaLayer]
    static let imagesKey = "holdmytrack:images"

    /// The picked categories, the captures and capture mode's target (-1 for none) into state,
    /// as the spots group's switch and vars: every layer hidden with none picked.
    public static func apply(categories: [SpotCategory], captured: [Int: Date], target: Int?, to state: inout MapState) {
        state.toggles[group] = !categories.isEmpty
        state.vars["spotCategories"] = .array(categories.map { .string($0.rawValue) })
        state.vars["captured"] = .array(captured.keys.sorted().map { .number(Double($0)) })
        state.vars["captureTarget"] = .number(Double(target ?? -1))
    }

    /// Every badge image the group's layers name, by name.
    public static func badges(_ document: LayersDocument) -> [String: SpotBadge] {
        var out: [String: SpotBadge] = [:]
        for layer in document.groups.first(where: { $0.id == group })?.layers ?? [] {
            for (name, b) in layer["metadata"]?[imagesKey]?.object ?? [:] {
                guard let category = b["category"]?.string.flatMap(SpotCategory.init(rawValue:)),
                      let fill = b["fill"]?.string, let ring = b["ring"]?.string, let ink = b["ink"]?.string else { continue }
                out[name] = SpotBadge(category: category, fill: fill, ring: ring, ink: ink)
            }
        }
        return out
    }

    /// The places' outline color, which capture's guide line is drawn in: the line layer the
    /// document marks `spot-area`.
    public static func areaColor(_ document: LayersDocument) -> String? {
        document.groups.lazy.flatMap(\.layers).first { $0["metadata"]?["holdmytrack:role"]?.string == "spot-area" }?["paint"]?["line-color"]?.string
    }

    /// The zooms "Show in this area" offers places between, its layer's: from a metro area in view
    /// to where the tiles start.
    public static func inAreaZooms(_ document: LayersDocument) -> Range<Double>? {
        let layer = document.groups.first { $0.id == group }?.layers.first { $0["id"]?.string == inAreaLayer }
        guard let min = layer?["minzoom"]?.number, let max = layer?["maxzoom"]?.number, min < max else { return nil }
        return min..<max
    }

    /// "Show in this area"'s places as its source's data, with the properties a tile's badge has.
    public static func inAreaFeatures(_ spots: [Spot]) -> JSONValue {
        let features: [JSONValue] = spots.map { spot in
            var properties: [String: JSONValue] = [
                "id": .number(Double(spot.id)), "category": .string(spot.category), "lon": .number(spot.lon), "lat": .number(spot.lat),
            ]
            for (key, value) in [("name", spot.name), ("address", spot.address), ("description", spot.description),
                                 ("inscription", spot.inscription), ("memorial", spot.memorial), ("start_date", spot.startDate),
                                 ("wikipedia", spot.wikipedia)] {
                if let value { properties[key] = .string(value) }
            }
            return .object([
                "type": .string("Feature"),
                "properties": .object(properties),
                "geometry": .object(["type": .string("Point"), "coordinates": .array([.number(spot.lon), .number(spot.lat)])]),
            ])
        }
        return .object(["type": .string("FeatureCollection"), "features": .array(features)])
    }

    /// A view's west and east edges as `GET /v1/spots` takes them: bounds more than 180° wide, at
    /// the zooms "Show in this area" works at, are a view across the antimeridian reported the
    /// long way round, so the edges swap, east past 180.
    public static func viewEdges(west: Double, east: Double) -> (west: Double, east: Double) {
        east - west > 180 ? (east, west + 360) : (west, east)
    }

    /// What `GET /v1/spots/captures` is asked for on a return to the map: since the newest
    /// capture known, or everything with none.
    public static func capturesSince(_ known: [Int: Date]) -> Date? { known.values.max() }

    /// known with fresh added: a capture is never changed or removed (root
    /// docs/IMPLEMENTATION.md §4.25), so what an answer since the newest leaves out stands.
    public static func merge(_ known: [Int: Date], _ fresh: [Int: Date]) -> [Int: Date] {
        known.merging(fresh) { _, new in new }
    }

    // MARK: The popup's text

    /// What Copy copies: OSM's address, or the coordinates, which every navigator accepts.
    public static func address(_ spot: Spot) -> String {
        spot.address ?? String(format: "%.6f, %.6f", locale: Locale(identifier: "en_US_POSIX"), spot.lat, spot.lon)
    }

    /// The article OSM's `wikipedia` tag names, "lang:Article title", on that language's
    /// Wikipedia, encoded as the web's `encodeURIComponent` does. Nil for a tag without a language.
    public static func wikipediaURL(_ tag: String) -> URL? {
        guard let colon = tag.firstIndex(of: ":") else { return nil }
        let lang = tag[..<colon].trimmingCharacters(in: .whitespaces)
        let title = tag[tag.index(after: colon)...].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_")
        var allowed = CharacterSet.alphanumerics.intersection(.init(charactersIn: Unicode.Scalar(0)..<Unicode.Scalar(128)))
        allowed.insert(charactersIn: "-_.!~*'()")
        guard !lang.isEmpty, let encoded = title.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://\(lang).wikipedia.org/wiki/\(encoded)")
    }

    /// OSM's `memorial` type as words, "war_memorial" to "War memorial": OSM's own English
    /// vocabulary, shown as it is in every language, as on the web.
    public static func memorialLabel(_ memorial: String) -> String {
        let words = memorial.replacingOccurrences(of: "[_;]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

/// "Show in this area" (root docs/SPEC.md FR-15.5): between a metro area in view and where the
/// tiles start, places load on request for the visible map and the picked categories, and stay
/// drawn until the next request. Once a load is current, the map not moved and no category
/// picked since, the pill says what it found instead of offering another.
public struct ShowInArea: Equatable, Sendable {
    public enum Label: Equatable, Sendable {
        case offer, loading, failed
        case none, truncated(shown: Int, total: Int), count(Int)
    }

    struct Loaded: Equatable, Sendable {
        let categories: Set<SpotCategory>
        let shown: Int
        let total: Int
    }

    var loaded: Loaded?
    var moved = false
    public private(set) var loading = false
    var failed = false

    public init() {}

    /// Nil hides the pill: nothing picked, or outside its zooms.
    public func label(categories: [SpotCategory], zoom: Double, zooms: Range<Double>?) -> Label? {
        guard !categories.isEmpty, let zooms, zooms.contains(zoom) else { return nil }
        if loading { return .loading }
        if failed { return .failed }
        guard let last = loaded, !moved, last.categories.isSuperset(of: categories) else { return .offer }
        if last.total == 0 { return Label.none }
        return last.shown < last.total ? .truncated(shown: last.shown, total: last.total) : .count(last.total)
    }

    public mutating func cameraMoved() { moved = true }

    public mutating func started() {
        loading = true
        failed = false
    }

    public mutating func finished(categories: [SpotCategory], shown: Int, total: Int) {
        loading = false
        loaded = Loaded(categories: Set(categories), shown: shown, total: total)
        moved = false
    }

    public mutating func failedLoading() {
        loading = false
        failed = true
    }
}

extension APIClient {
    /// `GET /v1/spots`: the picked categories' places in the box, up to the server's cap, and how
    /// many there are in all.
    public func spotsInArea(west: Double, south: Double, east: Double, north: Double, categories: [SpotCategory]) async throws -> (spots: [Spot], total: Int) {
        let box = [west, south, east, north].map { String(format: "%.5f", locale: Locale(identifier: "en_US_POSIX"), $0) }.joined(separator: ",")
        let json: SpotsInAreaJSON = try decode(try await send("GET", "v1/spots", query: [
            URLQueryItem(name: "bbox", value: box),
            URLQueryItem(name: "categories", value: categories.map(\.rawValue).joined(separator: ",")),
        ]))
        return (json.spots.map(Spot.init), json.total)
    }

    /// `GET /v1/spots/captures`: the account's captures by place, since a time or all of them.
    public func spotCaptures(since: Date?) async throws -> [Int: Date] {
        let query = since.map { [URLQueryItem(name: "since", value: Self.instant($0))] } ?? []
        let json: SpotCapturesJSON = try decode(try await send("GET", "v1/spots/captures", query: query))
        return Dictionary(json.captures.compactMap { c in Self.instant(c.capturedAt).map { (c.spotID, $0) } }, uniquingKeysWith: { _, b in b })
    }

    /// An RFC 3339 time, with or without fractions of a second.
    static func instant(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: text)
    }

    static func instant(_ date: Date) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.string(from: date)
    }
}