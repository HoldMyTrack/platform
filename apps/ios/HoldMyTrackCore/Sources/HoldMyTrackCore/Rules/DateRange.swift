// The date slider's selection and the rules that move it. Each rule here is one the web and
// Android implement too, held to the same cases in testdata/client-rules (ADR-0049).

/// A run of days, both ends inclusive, as YYYY-MM-DD, which compare as strings.
public struct DateRange: Equatable, Hashable, Sendable {
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// The default date range (docs/SPEC.md FR-6.1): the most recent `days` activity days in the
/// slider's window, through today. With no days in the window it starts at the earliest
/// activity, else today.
public enum DefaultRange {
    public static let days = 5

    /// visibleDates ascending.
    /// An activity day is in its own zone, so one recorded east of the account's can be later
    /// than today; the range then runs to it.
    public static func of(_ visibleDates: [String], earliest: String?, today: String) -> DateRange {
        let recent = visibleDates.suffix(days)
        let to = recent.last.map { $0 > today ? $0 : today } ?? today
        return DateRange(from: recent.first ?? earliest ?? today, to: to)
    }
}

/// Where the date slider's range-shift buttons move a selection: the same number of activity
/// days, packed right up against the old range on the side it moves toward.
public enum RangeShift: Equatable, Sendable {
    case shifted(DateRange)
    /// Nowhere to go.
    case none
    /// The days it needs are older than what's loaded: fetch the next page and ask again.
    case load

    /// days is the loaded run of activity days (ascending, ending at the newest); hasEarlier
    /// says whether more history sits before it, unloaded. Near either end of the history the
    /// shifted range stops at that end at its full size rather than shrinking.
    public static func of(days: [String], hasEarlier: Bool, range: DateRange, dir: Int) -> RangeShift {
        let n = days.count
        if n == 0 { return .none }
        // The selection's first and last activity days, as indices. A range holding none still
        // counts as one day wide, so the shift reaches the next day that has one.
        let first = days.firstIndex { $0 >= range.from } ?? n
        let last = days.lastIndex { $0 <= range.to } ?? -1
        if first == 0 && range.from < days[0] && hasEarlier { return .load }
        let size = max(1, last - first + 1)

        if dir < 0 {
            if first == 0 { return hasEarlier ? .load : .none }
            var start = first - size
            if start < 0 {
                if hasEarlier { return .load }
                start = 0
            }
            return .shifted(DateRange(from: days[start], to: days[min(start + size, n) - 1]))
        }

        if last >= n - 1 { return .none }
        let end = min(last + size, n - 1)
        return .shifted(DateRange(from: days[max(end - size + 1, 0)], to: days[end]))
    }
}
