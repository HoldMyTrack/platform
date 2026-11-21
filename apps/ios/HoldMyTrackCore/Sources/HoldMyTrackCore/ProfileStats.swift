import Foundation

/// One local day with tracks, from `GET /v2/tracks/histogram`.
public struct TrackDay: Equatable, Sendable {
    /// "2026-11-21", the account's own local day.
    public let date: String
    public let count: Int
    public let distanceMeters: Double

    public init(date: String, count: Int, distanceMeters: Double) {
        self.date = date
        self.count = count
        self.distanceMeters = distanceMeters
    }
}

/// The You tab's numbers and its glance at the track graph, by the web Profile page's rules
/// (services/server/internal/httpapi/profile_page.go), as Android's ProfileStats. The days are
/// the histogram's buckets: ascending, never one without a track.
public enum ProfileStats {
    public struct Totals: Equatable, Sendable {
        public let count: Int
        public let distanceMeters: Double
        public let activeDays: Int
        public let longestStreakDays: Int
    }

    /// Count and distance are sums, active days the number of days, the streak the longest run
    /// of consecutive ones.
    public static func totals(_ days: [TrackDay]) -> Totals {
        var count = 0, distance = 0.0, run = 0, longest = 0
        var previous: Date?
        for day in days {
            count += day.count
            distance += day.distanceMeters
            let date = Self.date(day.date)
            if let previous, let date, calendar.dateComponents([.day], from: previous, to: date).day == 1 { run += 1 } else { run = 1 }
            longest = max(longest, run)
            previous = date
        }
        return Totals(count: count, distanceMeters: distance, activeDays: days.count, longestStreakDays: longest)
    }

    /// The last weeks weeks through today, Sunday to Saturday column by column as a year's grid
    /// is, the last column this week. Each cell is shaded by count, as the grid's shadeLevel does:
    /// 0 for none, then 1, 2, and 3 for three or more; the days after today are -1, left blank.
    public static func recentWeeks(_ days: [TrackDay], today: String, weeks: Int) -> [Int] {
        guard let end = date(today) else { return [] }
        let byDate = Dictionary(days.map { ($0.date, $0.count) }, uniquingKeysWith: +)
        let weekday = calendar.component(.weekday, from: end) // 1 is Sunday
        guard let sunday = calendar.date(byAdding: .day, value: -(weekday - 1) - 7 * (weeks - 1), to: end) else { return [] }
        return (0..<(weeks * 7)).map { i in
            guard let day = calendar.date(byAdding: .day, value: i, to: sunday) else { return -1 }
            if day > end { return -1 }
            return min(byDate[string(day)] ?? 0, 3)
        }
    }

    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private static func date(_ text: String) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func string(_ date: Date) -> String {
        let p = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", p.year!, p.month!, p.day!)
    }
}
