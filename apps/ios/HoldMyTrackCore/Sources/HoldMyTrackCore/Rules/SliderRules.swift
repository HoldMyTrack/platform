/// The date-range slider's rules (root docs/SPEC.md FR-6), as plain values: how many activity
/// days fit, where a date's knob sits, what a knob move or a pan does to the selection, and how
/// the window follows a range.
///
/// Days are the window's activity days (YYYY-MM-DD, ascending). Boundary b is where slot b begins
/// (0...n). A date before the window is -1 and one after it n + 1, off-screen, unless there's no
/// history on that side, where it sits on the edge: today with nothing recorded yet still has its
/// end knob on the right edge.
public enum SliderRules {
    /// « »'s width, its gap to the track, and the track's inset each side, in points.
    private static let page = 22
    private static let gap = 6
    private static let pad = 8

    /// The narrowest activity day: two knobs a day apart stay apart.
    private static let minSlot = 18
    public static let minDays = 7
    public static let maxDays = 31

    /// « » show only if the track still holds this many days beside them.
    private static let buttonsFrom = 12

    /// The slots a month's name needs before the next one: about 30pt of text in two 18pt
    /// slots. Where the next starts sooner, the earlier name is dropped.
    private static let labelSlots = 2

    public struct Layout: Equatable, Sendable {
        public let buttons: Bool
        public let days: Int
    }

    /// How many activity days the window holds at width points (the room for « track »), and
    /// whether « » show: always for a fine pointer, which has no swipe; otherwise only where they
    /// leave enough track.
    public static func layout(width: Int, finePointer: Bool) -> Layout {
        let withButtons = width - 2 * (page + gap) - 2 * pad
        let buttons = finePointer || floorDiv(withButtons, minSlot) >= buttonsFrom
        let track = buttons ? withButtons : width - 2 * pad
        return Layout(buttons: buttons, days: min(max(floorDiv(track, minSlot), minDays), maxDays))
    }

    /// The window: its days and whether there's history beyond either end.
    public struct Window: Equatable, Sendable {
        public let days: [String]
        public let canPanEarlier: Bool
        public let canPanLater: Bool

        public init(days: [String], canPanEarlier: Bool, canPanLater: Bool) {
            self.days = days
            self.canPanEarlier = canPanEarlier
            self.canPanLater = canPanLater
        }
    }

    /// The boundaries of range's two knobs: start where its first day begins, end where its last
    /// one ends.
    public static func boundaries(_ window: Window, _ range: DateRange) -> (start: Int, end: Int) {
        let days = window.days
        let n = days.count
        guard let first = days.first, let last = days.last else { return (0, 0) }
        let start: Int
        if range.from < first {
            start = window.canPanEarlier ? -1 : 0
        } else if let i = days.firstIndex(where: { $0 >= range.from }) {
            start = i
        } else {
            start = window.canPanLater ? n + 1 : n
        }
        let end: Int
        if range.to > last {
            end = window.canPanLater ? n + 1 : n
        } else if range.to < first {
            end = window.canPanEarlier ? -1 : 0
        } else {
            end = days.count { $0 <= range.to }
        }
        return (start, end)
    }

    public enum Knob: Sendable { case start, end }

    /// One knob moved to boundary b, a slot from the other (pushing it if needed). A knob that
    /// ends up where it already was keeps its own date, which may lie off-screen or in a gap
    /// between activity days; only a knob that moved takes a slot's date.
    public static func moveKnob(_ window: Window, _ range: DateRange, knob: Knob, to b: Int) -> DateRange {
        let days = window.days
        let n = days.count
        if n == 0 { return range }
        let (s0, e0) = boundaries(window, range)
        var s = s0
        var e = e0
        switch knob {
        case .start:
            s = min(max(b, 0), n - 1)
            e = max(e0, s + 1)
        case .end:
            e = min(max(b, 1), n)
            s = min(s0, e - 1)
        }
        return DateRange(from: s == s0 ? range.from : days[s], to: e == e0 ? range.to : days[e - 1])
    }

    /// A tick on boundary: tall where a month starts (monthStart), and the month (1...12)
    /// labelled from it: each month start, and the first month in view at the left edge, unless
    /// the next label is too close.
    public struct Tick: Equatable, Sendable {
        public let boundary: Int
        public let monthStart: Bool
        public var month: Int?
    }

    /// A tick on every boundary 0...n; the outer two are plain.
    public static func ticks(_ days: [String]) -> [Tick] {
        if days.isEmpty { return [] }
        func month(_ date: String) -> Int { Int(date.dropFirst(5).prefix(2))! }
        var ticks = (0...days.count).map { b -> Tick in
            let before = b > 0 ? days[b - 1] : nil
            let after = b < days.count ? days[b] : nil
            guard let before else { return Tick(boundary: b, monthStart: false, month: month(after!)) }
            guard let after, before.prefix(7) != after.prefix(7) else { return Tick(boundary: b, monthStart: false, month: nil) }
            return Tick(boundary: b, monthStart: true, month: month(after))
        }
        var next = Int.max
        for b in ticks.indices.reversed() where ticks[b].month != nil {
            if next - b < labelSlots { ticks[b].month = nil } else { next = b }
        }
        return ticks
    }

    /// A pan has landed on the window days: the knobs it was carrying (start, end) move onto the
    /// new edges, the other one pushed if they'd cross.
    public static func panLand(days: [String], range: DateRange, start: Bool, end: Bool) -> DateRange {
        guard let first = days.first, let last = days.last else { return range }
        var next = range
        if start { next = DateRange(from: first, to: next.to < first ? first : next.to) }
        if end { next = DateRange(from: next.from > last ? last : next.from, to: last) }
        return next
    }

    /// Where a window of windowDays over count loaded days, now from left, moves to show the days
    /// first...last (indices): as little as it takes; for a run longer than the window, its edge
    /// on the dir side (-1 the start, 1 the end).
    public static func windowFit(count: Int, windowDays: Int, left: Int, first: Int, last: Int, dir: Int) -> Int {
        let maxStart = max(0, count - windowDays)
        let next: Int
        if last - first + 1 > windowDays {
            next = dir < 0 ? first : last - windowDays + 1
        } else if first < left {
            next = first
        } else if last >= left + windowDays {
            next = last - windowDays + 1
        } else {
            next = left
        }
        return min(max(next, 0), maxStart)
    }

    /// Division rounding toward negative infinity, as a narrow width's negative room needs.
    private static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }
}
