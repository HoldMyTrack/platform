/// A number to write in the language's digits, with minDecimals to maxDecimals decimals and
/// thousands grouping or not, followed by unit.
public struct DistanceParts: Equatable, Sendable {
    public let value: Double
    public let minDecimals: Int
    public let maxDecimals: Int
    public let grouping: Bool
    public let unit: DistanceUnit
}

public enum DistanceUnit: String, Sendable { case km, mi }

/// A duration message: "3h 52m", "43m" or "20s".
public enum DurationParts: Equatable, Sendable {
    case hoursMinutes(h: Int, m: Int)
    case minutes(Int)
    case seconds(Int)
}

/// What the panel decides before the language writes it: which number, how many decimals,
/// which unit or message.
public enum FormatParts {
    private static let metersPerMile = 1609.344

    private static func converted(_ meters: Double, imperial: Bool) -> Double {
        imperial ? meters / metersPerMile : meters / 1000
    }

    /// An activity's distance: always one decimal, never grouped.
    public static func distance(meters: Double, imperial: Bool) -> DistanceParts {
        DistanceParts(value: converted(meters, imperial: imperial), minDecimals: 1, maxDecimals: 1, grouping: false, unit: imperial ? .mi : .km)
    }

    /// A range's total: one decimal below 10 (km or mi), so a short history never reads as a
    /// flat "0 km", and whole units from 10 up.
    public static func totalDistance(meters: Double, imperial: Bool) -> DistanceParts {
        let value = converted(meters, imperial: imperial)
        return DistanceParts(value: value, minDecimals: 0, maxDecimals: value < 10 ? 1 : 0, grouping: true, unit: imperial ? .mi : .km)
    }

    /// Hours and minutes from an hour up, minutes from a minute, else seconds.
    public static func duration(seconds: Int) -> DurationParts {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 { return .hoursMinutes(h: h, m: m) }
        if m > 0 { return .minutes(m) }
        return .seconds(seconds)
    }
}
