/// What Fog's place popup says about an outline a tap picked, the web's `fogPlaceLabel.ts`: from
/// the outline's tile feature its name, kind, the places it lies in, whether it's explored, and
/// how many of each level below it the account has explored. Keys are the web's catalog keys,
/// which the app maps to its strings. Shared cases: testdata/client-rules/fog-place-label.json.
public enum FogPlaceLabel {
    /// Of a level below the place, how many of its places in it the account has been in out of
    /// total, and the plural catalog key naming them in its country's words.
    public struct Count: Equatable, Sendable {
        public let key: String
        public let explored: Int
        public let total: Int
    }

    public struct Label: Equatable, Sendable {
        public let name: String
        public let kindKey: String
        /// The places it lies in, nearest first, or "" for a country.
        public let within: String
        public let visitedKey: String
        /// Coarsest level first; empty for a city or a stand-in.
        public let counts: [Count]

        public var visited: Bool { visitedKey == FogPlaceLabel.visitedKey }
    }

    static let visitedKey = "map.fog.place.visited"

    /// The levels a place counts below it: the tile's column, the column naming them in its
    /// country's words, and what they're called anywhere.
    private static let counted: [(String, String?, String)] = [
        ("regions", "region_word", "region"),
        ("counties", "county_word", "county"),
        ("cities", nil, "city"),
    ]

    private static let kinds: Set<String> = ["country", "region", "county", "city"]

    /// The label for an outline's props, or nil for the sea or a feature it can't name. has is
    /// whether the catalog has a key, a plural by its `.other` form: the kind is the place's own,
    /// as its country files it (Overture's local_type), where there's a word for it, else the
    /// level's.
    public static func of(_ props: [String: JSONValue], has: (String) -> Bool) -> Label? {
        guard let kind = props["kind"]?.string, kinds.contains(kind),
              let name = props["name"]?.string, !name.isEmpty else { return nil }
        let own = props["type"]?.string.map { "map.fog.type.\($0)" }
        // A boolean in the tile; a JSON round trip can make it a string.
        let visited = props["visited"] == .bool(true) || props["visited"] == .string("true")
        let counts: [Count] = counted.compactMap { level, wordColumn, generic in
            guard let explored = props[level]?.number, let total = props["\(level)_total"]?.number, total > 0 else { return nil }
            var key = "map.fog.count.\(generic)"
            if let column = wordColumn, let word = props[column]?.string, !word.isEmpty, has("map.fog.count.\(word).other") {
                key = "map.fog.count.\(word)"
            }
            return Count(key: key, explored: Int(explored), total: Int(total))
        }
        return Label(
            name: name,
            kindKey: own.flatMap { has($0) ? $0 : nil } ?? "map.fog.place.\(kind)",
            within: props["within"]?.string ?? "",
            visitedKey: visited ? visitedKey : "map.fog.place.unvisited",
            counts: counts
        )
    }
}