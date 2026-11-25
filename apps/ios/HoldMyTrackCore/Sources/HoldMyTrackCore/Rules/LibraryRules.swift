/// What Library (apps/android/docs/SPEC.md FR-4.1, root docs/SPEC.md FR-17.1) decides, as plain
/// values: the request a state asks for, the pager and why a page is empty. The web's
/// `apps/web/src/library/libraryState.ts` and Android's `panel/LibraryRules`; all three run
/// testdata/client-rules/library-*.json.
public enum LibraryRules {
    public enum Sort: String, Sendable, CaseIterable {
        case started, distance, moving, added
    }

    /// Meters; max nil is unbounded.
    public struct Distance: Equatable, Sendable {
        public var min: Double
        public var max: Double?

        public init(min: Double, max: Double?) {
            self.min = min
            self.max = max
        }
    }

    public struct State: Equatable, Sendable {
        public var sort: Sort = .started
        public var desc = true
        public var page = 1
        public var q = ""
        /// Types left out, as the Tracks tab's Type filter holds them.
        public var exclude: Set<String> = []
        public var distance: Distance?
        public var after: String?
        public var before: String?
        public var trip: String?

        public init(
            sort: Sort = .started, desc: Bool = true, page: Int = 1, q: String = "", exclude: Set<String> = [],
            distance: Distance? = nil, after: String? = nil, before: String? = nil, trip: String? = nil
        ) {
            self.sort = sort
            self.desc = desc
            self.page = page
            self.q = q
            self.exclude = exclude
            self.distance = distance
            self.after = after
            self.before = before
            self.trip = trip
        }

        /// This state after a filter, the search or the sort changed: back on page 1, since the
        /// page the reader was on means something else now.
        public func withFilter(_ change: (inout State) -> Void) -> State {
            var next = self
            change(&next)
            next.page = 1
            return next
        }

        /// Whether any filter or the search is on: the count then says how many match.
        public var anyFilter: Bool {
            !q.isEmpty || !exclude.isEmpty || distance != nil || after != nil || before != nil || trip != nil
        }
    }

    /// The query state asks for, given every type the account has (allTypes, the bounds'): the
    /// Type filter sent as the types kept. Nil when every type is left out, which matches no track.
    public static func pageQuery(_ state: State, allTypes: [String]) -> TrackPageQuery? {
        var types: [String]?
        if !state.exclude.isEmpty, !allTypes.isEmpty {
            let kept = allTypes.filter { !state.exclude.contains($0) }
            if kept.isEmpty { return nil }
            types = kept
        }
        return TrackPageQuery(
            page: state.page,
            sort: "\(state.sort.rawValue)_\(state.desc ? "desc" : "asc")",
            q: state.q.isEmpty ? nil : state.q,
            types: types,
            minDistance: state.distance.flatMap { $0.min > 0 ? $0.min : nil },
            maxDistance: state.distance?.max,
            from: state.after,
            to: state.before,
            trip: state.trip
        )
    }

    public struct Pager: Equatable, Sendable {
        public let from: Int
        public let to: Int
        public let prev: Bool
        public let next: Bool
    }

    /// The rows page shows, 1-based, and whether there is a page before and after; nil when it
    /// shows no row.
    public static func pager(page: Int, total: Int, pageSize: Int) -> Pager? {
        let from = (page - 1) * pageSize + 1
        if total == 0 || from > total { return nil }
        let to = Swift.min(page * pageSize, total)
        return Pager(from: from, to: to, prev: page > 1, next: to < total)
    }

    public enum EmptyReason: String, Sendable {
        case noTracks = "no_tracks"
        case pastLast = "past_last"
        case search
        case searchAndFilters = "search_and_filters"
        case filters
    }

    /// Why a page has no row: no track at all; past the last page, whatever the filters (a Delete
    /// can empty the last page); the search, with or without other filters to clear; or only the
    /// filters.
    public static func emptyReason(_ state: State, total: Int, anyTrack: Bool) -> EmptyReason {
        if !anyTrack { return .noTracks }
        if total > 0 { return .pastLast }
        if !state.q.isEmpty {
            var rest = state
            rest.q = ""
            return rest.anyFilter ? .searchAndFilters : .search
        }
        return .filters
    }

    /// Checked after the rows changed: only the ids still listed, since Checked stays within a page.
    public static func keepListed(_ checked: Set<String>, rows: [String]) -> Set<String> {
        checked.intersection(rows)
    }
}
