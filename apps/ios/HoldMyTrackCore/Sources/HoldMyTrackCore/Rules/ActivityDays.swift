import Foundation

/// The date slider's window over the account's history, by days that have activity (root
/// docs/SPEC.md FR-6): Android's ActivityDays and the web's useActivityDays, as a value. One slot
/// per day with an activity, none for the days between. Pages come newest first from
/// `GET /v1/activities/histogram?days=&before=`, so what's loaded is one run of activity days ending
/// at the most recent, grown by prepending; the app fetches when `wantsEarlier` names a day. The
/// window's position is its leftmost day, not an index, since a prepended page shifts every index;
/// nil keeps it on the newest end. Nothing here touches the selection.
public struct ActivityDays: Equatable, Sendable {
    /// Activity days per request: far more than a window, so paging back rarely waits.
    public static let pageSize = 240

    public private(set) var windowDays: Int
    public private(set) var days: [String] = []
    /// The account's first activity day, nil until a first page and for an account with none.
    public private(set) var earliest: String?
    /// True once a first page has come back, however empty.
    public private(set) var ready = false
    private var anchor: String?
    /// Days a pan asked for that aren't loaded yet, carried until they are.
    private var carry = 0

    public init(windowDays: Int) {
        self.windowDays = windowDays
    }

    private var maxStart: Int { max(0, days.count - windowDays) }

    private var start: Int {
        guard let anchor else { return maxStart }
        return min(days.firstIndex { $0 >= anchor } ?? maxStart, maxStart)
    }

    /// Whether there is history behind what's loaded: a short page is what running out looks like.
    private var hasEarlier: Bool {
        guard let first = days.first, let earliest else { return false }
        return first > earliest
    }

    /// The days in the window, ascending.
    public var visibleDays: [String] { Array(days[start..<min(days.count, start + windowDays)]) }
    public var canPanEarlier: Bool { start > 0 || hasEarlier }
    public var canPanLater: Bool { start < maxStart }

    /// The day to load the page before, once the window is within one window of the loaded edge,
    /// so Earlier normally lands on days already here; nil when nothing is to be loaded.
    public var wantsEarlier: String? {
        hasEarlier && start <= windowDays ? days.first : nil
    }

    /// A first page, from the newest end: on every return to the map, since an upload may have
    /// added days. An anchored window stays on its day, loading the page before it if needed.
    public mutating func reloaded(days page: [String], earliest: String?) {
        days = page
        self.earliest = earliest
        carry = 0
        ready = true
    }

    /// The page before oldest; dropped if the loaded days no longer start there (a reload came
    /// first). A pan waiting on it settles now, the window not jumping.
    public mutating func prepended(days page: [String], before oldest: String, earliest: String?) {
        guard days.first == oldest else { return }
        days = page + days
        self.earliest = earliest
        let owed = carry
        if owed < 0 {
            carry = 0
            pan(by: owed)
        }
    }

    /// Moves the window by whole activity days, negative toward the past.
    public mutating func pan(by delta: Int) {
        let target = start + delta
        let next = min(max(target, 0), maxStart)
        carry = target < 0 && hasEarlier ? target : 0
        anchor = next >= maxStart ? nil : (days.indices.contains(next) ? days[next] : nil)
    }

    /// A new window size: on the newest end it stays there; elsewhere it keeps selection in view,
    /// its end day where it was.
    public mutating func resize(_ size: Int, selection: DateRange?) {
        guard size != windowDays else { return }
        let left = start
        windowDays = size
        guard anchor != nil, let selection, let first = days.firstIndex(where: { $0 >= selection.from }) else { return }
        let last = days.filter { $0 <= selection.to }.count - 1
        guard last >= first else { return }
        let next = SliderRules.windowFit(count: days.count, windowDays: size, left: left, first: first, last: last, dir: 1)
        anchor = next >= maxStart ? nil : days[next]
    }

    /// ‹ ›: range moved its own length, the window moved just enough to show it; nil when there's
    /// nothing further that way, or the days it needs are still to load (wantsLoad then).
    public mutating func shift(_ range: DateRange, dir: Int) -> (range: DateRange?, wantsLoad: Bool) {
        switch RangeShift.of(days: days, hasEarlier: hasEarlier, range: range, dir: dir) {
        case .none: return (nil, false)
        case .load: return (nil, true)
        case .shifted(let next):
            let left = start
            let to = SliderRules.windowFit(count: days.count, windowDays: windowDays, left: left,
                                           first: days.firstIndex(of: next.from) ?? 0, last: days.firstIndex(of: next.to) ?? 0, dir: dir)
            if to != left { anchor = to >= maxStart ? nil : days[to] }
            return (next, false)
        }
    }

    /// Whether shift has anywhere to go, true while the days it needs are only unloaded.
    public func canShift(_ range: DateRange, dir: Int) -> Bool {
        RangeShift.of(days: days, hasEarlier: hasEarlier, range: range, dir: dir) != .none
    }
}

/// The selected range as the slider's heading, the year said once: "3 Oct 2026",
/// "24 – 28 Sep 2026", "24 Sep – 3 Oct 2026", "28 Dec 2025 – 3 Jan 2026"; months in locale's form.
public enum RangeLabel {
    public static func of(_ range: DateRange, locale: Locale) -> String {
        let parse = DateFormatter()
        parse.calendar = Calendar(identifier: .gregorian)
        parse.timeZone = TimeZone(identifier: "UTC")
        parse.dateFormat = "yyyy-MM-dd"
        guard let from = parse.date(from: range.from), let to = parse.date(from: range.to) else { return "" }
        // Day first in every language, as Android writes it; only the month's name is locale's.
        func format(_ pattern: String, _ date: Date) -> String {
            let f = DateFormatter()
            f.locale = locale
            f.calendar = Calendar(identifier: .gregorian)
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = pattern
            return f.string(from: date)
        }
        let calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
        let a = calendar.dateComponents([.year, .month, .day], from: from), b = calendar.dateComponents([.year, .month, .day], from: to)
        if range.from == range.to { return format("d MMM yyyy", to) }
        if a.year != b.year { return "\(format("d MMM yyyy", from)) – \(format("d MMM yyyy", to))" }
        if a.month == b.month { return "\(a.day!) – \(format("d MMM yyyy", to))" }
        return "\(format("d MMM", from)) – \(format("d MMM yyyy", to))"
    }
}
