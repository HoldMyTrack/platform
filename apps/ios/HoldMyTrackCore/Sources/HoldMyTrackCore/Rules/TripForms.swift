/// What the Trip sheets allow, as values (root docs/SPEC.md FR-13.2, FR-13.7).
public enum TripForms {
    /// The server's maxTripNameLen and maxTripDescriptionLen (services/server/internal/httpapi/trips.go).
    public static let nameLimit = 200
    public static let descriptionLimit = 2000

    /// Whether Create trip, Save or Send can be tapped (testdata/client-rules/trip-form-action.json):
    /// its field needs text besides whitespace, and no request may be running.
    public static func actionEnabled(text: String, busy: Bool) -> Bool {
        !busy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// How long the server counts text: in Unicode scalars, its runes, not the characters shown.
    public static func length(_ text: String) -> Int { text.unicodeScalars.count }

    /// The start of inserted that fits in room scalars, whole characters only, so a paste past
    /// the limit keeps what fits instead of nothing.
    public static func fitting(_ inserted: String, room: Int) -> String {
        var used = 0
        var kept = ""
        for character in inserted {
            let size = character.unicodeScalars.count
            if used + size > room { break }
            used += size
            kept.append(character)
        }
        return kept
    }
}
