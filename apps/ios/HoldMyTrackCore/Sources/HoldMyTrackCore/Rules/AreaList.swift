import Foundation

/// Whether the list follows the map (root docs/SPEC.md FR-5.19): from zoom 4, where tracks are
/// drawn, on every settled move; further out there's nothing on the map to list. And whether the
/// last area's list was cut at the limit, so the map draws only the listed tracks and says so.
public enum AreaLoad {
    /// The most activities one area lists, and so its map draws (the server's areaActivitiesLimit).
    public static let limit = 1000
    /// Where tracks start being drawn, and the list with them.
    public static let minZoom = 4.0

    public enum Load: String, Sendable { case auto, none }

    /// listed and total are the last load's; total is nil before one.
    public static func of(zoom: Double, listed: Int, total: Int?) -> (load: Load, capped: Bool) {
        (zoom >= minZoom ? .auto : .none, total.map { $0 > listed } ?? false)
    }

    /// Two views the same to about a metre: an area the list was already asked about.
    public static func same(_ a: [Double]?, _ b: [Double]) -> Bool {
        guard let a, a.count == 4, b.count == 4 else { return false }
        return zip(a, b).allSatisfy { abs($0 - $1) < 1e-5 }
    }

    /// The visible map as the list's `bbox`, to about a metre, so a redraw asks nothing new.
    public static func box(west: Double, south: Double, east: Double, north: Double) -> [Double] {
        [west, south, east, north].map { ($0 * 1e5).rounded() / 1e5 }
    }
}

/// The opening camera (root docs/SPEC.md FR-4.5): zoom 12, centred on the newest five tracks if
/// they fit the screen there with three quarters of it filled, else the newest four, and so on;
/// when even the newest alone doesn't fit, still centred on it.
public enum OpeningView {
    public static let zoom = 12.0
    /// How many of the newest activities it tries to show.
    public static let activities = 5
    /// The share of the screen a flight's box may fill.
    static let fill = 0.75
    /// The world's width in points at zoom 0.
    static let worldPoints = 512.0

    /// boxes are the tracks' bounds, newest first; nil when there are none. center is (lon, lat).
    public static func of(_ boxes: [[Double]], width: Double, height: Double) -> (lon: Double, lat: Double, zoom: Double)? {
        guard let newest = boxes.first else { return nil }
        let scale = worldPoints * pow(2, zoom)
        func frame(_ b: [Double]) -> (width: Double, height: Double, x: Double, y: Double) {
            let (x0, y0) = mercator(b[0], b[3]), (x1, y1) = mercator(b[2], b[1])
            return ((x1 - x0) * scale, (y1 - y0) * scale, (x0 + x1) / 2, (y0 + y1) / 2)
        }
        var chosen = frame(newest)
        for n in stride(from: min(activities, boxes.count), through: 1, by: -1) {
            guard let union = MapFraming.union(Array(boxes.prefix(n))) else { continue }
            let f = frame(union)
            if f.width <= width * fill && f.height <= height * fill {
                chosen = f
                break
            }
        }
        return (wrapped(chosen.x * 360 - 180), latitude(chosen.y), zoom)
    }

    /// Web Mercator's x and y of a point, 0...1 across the world, y down.
    private static func mercator(_ lon: Double, _ lat: Double) -> (Double, Double) {
        let s = sin(lat * .pi / 180)
        return ((lon + 180) / 360, 0.5 - log((1 + s) / (1 - s)) / (4 * .pi))
    }

    private static func latitude(_ y: Double) -> Double { atan(sinh(.pi * (1 - 2 * y))) * 180 / .pi }

    /// A longitude within -180...180; 180 itself comes back as -180.
    private static func wrapped(_ lon: Double) -> Double {
        ((lon + 180).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) - 180
    }
}

/// The Dates filter (root docs/SPEC.md FR-5.20): From (after) and To (before), local YYYY-MM-DD
/// dates, both inclusive and either nil; both nil is all time.
public struct DateFilter: Equatable, Sendable {
    public var after: String?
    public var before: String?

    public static let allTime = DateFilter()

    /// Today in the account's zone (root docs/SPEC.md FR-1.7), as YYYY-MM-DD.
    public static func today(in zone: String, now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone) ?? TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// A day as its button shows it: "3 Jun", or "3 Jun 2025" outside today's year, the month in
    /// locale's form.
    public static func short(_ day: String, today: String, locale: Locale) -> String {
        let parse = DateFormatter()
        parse.calendar = Calendar(identifier: .gregorian)
        parse.timeZone = TimeZone(identifier: "UTC")
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.dateFormat = "yyyy-MM-dd"
        guard let date = parse.date(from: day) else { return day }
        let out = DateFormatter()
        out.locale = locale
        out.calendar = Calendar(identifier: .gregorian)
        out.timeZone = TimeZone(identifier: "UTC")
        out.setLocalizedDateFormatFromTemplate(day.prefix(4) == today.prefix(4) ? "dMMM" : "dMMMyyyy")
        return out.string(from: date)
    }

    public init(after: String? = nil, before: String? = nil) {
        self.after = after
        self.before = before
    }

    public enum End: Sendable { case after, before }

    /// What its button says, before wording: all time, both ends, or one.
    public enum Label: Equatable, Sendable {
        case all
        case between(after: String, before: String)
        case after(String)
        case before(String)
    }

    public var label: Label {
        switch (after, before) {
        case let (a?, b?): .between(after: a, before: b)
        case let (a?, nil): .after(a)
        case let (nil, b?): .before(b)
        case (nil, nil): .all
        }
    }

    /// The server's `from` and `to`, an empty end left out.
    public var query: [URLQueryItem] {
        [after.map { URLQueryItem(name: "from", value: $0) }, before.map { URLQueryItem(name: "to", value: $0) }].compactMap { $0 }
    }

    /// What the pickers allow: the first activity's day, today without one, to today, the
    /// account's, or the newest activity's day when that's later: one recorded in a zone ahead
    /// can be dated tomorrow.
    public static func bounds(earliest: String?, latest: String?, today: String) -> (min: String, max: String) {
        (earliest.map { $0 < today ? $0 : today } ?? today, latest.map { $0 > today ? $0 : today } ?? today)
    }

    /// The filter once one end is set to value, or cleared with nil: clamped into bounds, and the
    /// other end moved to meet it if they crossed. fly asks for the camera to move onto what it
    /// matches once: only setting a date does, never clearing one, nor a value that changed nothing.
    public func setting(_ end: End, to value: String?, bounds: (min: String, max: String)) -> (filter: DateFilter, fly: Bool) {
        var next = self
        let given = value.flatMap { $0.isEmpty ? nil : $0 }
        if let given {
            let date = given < bounds.min ? bounds.min : given > bounds.max ? bounds.max : given
            if end == .after { next.after = date } else { next.before = date }
            if let a = next.after, let b = next.before, a > b { next = DateFilter(after: date, before: date) }
        } else if end == .after {
            next.after = nil
        } else {
            next.before = nil
        }
        return (next, next != self && given != nil)
    }
}