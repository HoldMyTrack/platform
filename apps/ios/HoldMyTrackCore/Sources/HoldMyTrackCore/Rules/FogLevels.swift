/// Fog's levels (root docs/IMPLEMENTATION.md §4.2.4), the web's `fogLevels.ts`: which is in view,
/// what picking one in the level control does, and the zoom each level's layers draw at. Each
/// level draws at every zoom; its band, from the layers document, is where it draws by default.
/// Shared cases: testdata/client-rules/fog-level-*.json.
public enum FogLevels {
    /// A level and its band, from `from` (0 when nil) up to but not including `below` (no end when
    /// nil), with the layers that draw it and what the account's country calls its places
    /// (Overture's local_type), or nil for the generic name.
    public struct Level: Equatable, Sendable {
        public let level: String
        public let from: Double?
        public let below: Double?
        public let layers: [String]
        public let word: String?

        public init(level: String, from: Double? = nil, below: Double? = nil, layers: [String] = [], word: String? = nil) {
            self.level = level
            self.from = from
            self.below = below
            self.layers = layers
            self.word = word
        }

        init?(_ json: JSONValue) {
            guard let level = json["level"]?.string else { return nil }
            self.init(level: level, from: json["from"]?.number, below: json["below"]?.number,
                      layers: json["layers"]?.array?.compactMap(\.string) ?? [], word: json["word"]?.string)
        }
    }

    /// What a level is when nothing else is: the finest, drawing every track.
    public static let exact = "exact"

    /// Past MapLibre Native's deepest camera zoom (25.5): a range ending here has no end, and one
    /// starting here never draws. The web's 24 is MapLibre GL JS's.
    public static let maxZoom = 30.0

    /// The level in view: the locked one, else the one whose band holds zoom.
    public static func inView(_ levels: [Level], zoom: Double, locked: String? = nil) -> String {
        if let locked, levels.contains(where: { $0.level == locked }) { return locked }
        let inBand = levels.first { zoom >= ($0.from ?? 0) && ($0.below.map { zoom < $0 } ?? true) }
        return inBand?.level ?? levels.last?.level ?? exact
    }

    /// The lock after a pick, and the zoom to move the camera out to, keeping its centre, or nil
    /// to stay.
    public struct Pick: Equatable, Sendable {
        public let locked: String?
        public let zoom: Double?
    }

    /// Picking picked while locked is locked at zoom. Picking never zooms in: a level further in
    /// draws where the camera is.
    public static func pick(_ levels: [Level], zoom: Double, locked: String?, picked: String) -> Pick {
        guard let band = levels.first(where: { $0.level == picked }) else { return Pick(locked: locked, zoom: nil) }
        if picked == locked { return Pick(locked: nil, zoom: nil) }
        if let below = band.below, zoom >= below { return Pick(locked: picked, zoom: below) }
        return Pick(locked: picked, zoom: nil)
    }

    /// The lock while the document has its level: a lock on one it lacks follows the zoom.
    public static func lock(_ levels: [Level], _ locked: String?) -> String? {
        locked.flatMap { l in levels.contains { $0.level == l } ? l : nil }
    }

    /// Each level's layers' zoom range, nil for a layer the lock leaves as the document has it:
    /// with a level locked, every zoom for its layers and none for the others'.
    public static func zoomRanges(_ levels: [Level], locked: String?) -> [String: ClosedRange<Double>] {
        guard let lock = lock(levels, locked) else { return [:] }
        var ranges: [String: ClosedRange<Double>] = [:]
        for l in levels {
            let range = l.level == lock ? 0...maxZoom : maxZoom...maxZoom
            for id in l.layers { ranges[id] = range }
        }
        return ranges
    }

    /// How many places of each level the account has been in, as the map clears them
    /// (root docs/SPEC.md FR-4.2): the level menu's counts.
    public struct Explored: Equatable, Sendable {
        public let countries: Int
        public let regions: Int
        public let counties: Int
        public let cities: Int

        public init(countries: Int, regions: Int, counties: Int, cities: Int) {
            self.countries = countries
            self.regions = regions
            self.counties = counties
            self.cities = cities
        }
    }

    /// How many places of level the account has explored, or nil for a level that counts none:
    /// exact coverage.
    public static func exploredCount(_ explored: Explored, level: String) -> Int? {
        switch level {
        case "country": explored.countries
        case "region": explored.regions
        case "county": explored.counties
        case "city": explored.cities
        default: nil
        }
    }

    /// The catalog key naming level in the control: what the account's country calls its places
    /// (word) where the catalog has it, for regions and counties, else the generic name, the
    /// web's `levelLabelKey`; nil for a level this build doesn't know.
    public static func labelKey(_ level: String, word: String?, has: (String) -> Bool) -> String? {
        if level == "region" || level == "county", let word, has("map.fog.type.\(word)") { return "map.fog.type.\(word)" }
        return ["country", "region", "county", "city", exact].contains(level) ? "map.fog.level.\(level)" : nil
    }
}