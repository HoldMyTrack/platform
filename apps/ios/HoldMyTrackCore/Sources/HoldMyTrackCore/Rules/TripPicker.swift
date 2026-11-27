/// What Add to trip's picker sheet shows (TripPickerViewController), as Android's TripPicker.
public enum TripPicker {
    /// From this many Trips, the sheet has a search field.
    public static let searchFrom = 9

    /// A Trip as the picker needs it.
    public struct Entry: Equatable, Sendable {
        public let id: String
        public let name: String
        public let trackIDs: [String]

        public init(id: String, name: String, trackIDs: [String]) {
            self.id = id
            self.name = name
            self.trackIDs = trackIDs
        }
    }

    /// A row: holdsAll when the Trip has every target track already, so it can't be picked.
    public struct Row: Equatable, Sendable {
        public let id: String
        public let holdsAll: Bool
    }

    public struct Shown: Equatable, Sendable {
        public let search: Bool
        public let rows: [Row]
    }

    /// The rows for trips, newest first as the server sends them, over target, keeping those whose
    /// name holds query, ignoring case and the whitespace around it.
    public static func shown(_ trips: [Entry], target: [String], query: String) -> Shown {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = trips.filter { typed.isEmpty || $0.name.range(of: typed, options: .caseInsensitive) != nil }
            .map { Row(id: $0.id, holdsAll: Set(target).isSubset(of: $0.trackIDs)) }
        return Shown(search: trips.count >= searchFrom, rows: rows)
    }
}
