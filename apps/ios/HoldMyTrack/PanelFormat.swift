import Foundation
import HoldMyTrackCore
import UIKit

/// The Activities panel's numbers and dates in the app's language: FormatParts' decisions
/// written out, a start time as a medium date with a short time in the zone the activity was
/// recorded in (ActivityZone), units by the account's Country.
@MainActor
struct PanelFormat {
    let imperial: Bool
    /// The account's zone, for an activity with none of its own.
    let accountZone: String

    init(account: Account) {
        imperial = account.unitSystem == "imperial"
        accountZone = account.timezone
    }

    private static let dash = "—"

    var unit: String { unit(imperial ? .mi : .km) }

    private func unit(_ unit: DistanceUnit) -> String {
        unit == .mi ? String(localized: "mi", comment: "Distance unit: miles.") : String(localized: "km", comment: "Distance unit: kilometres.")
    }

    private func written(_ parts: DistanceParts) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = parts.minDecimals
        formatter.maximumFractionDigits = parts.maxDecimals
        formatter.usesGroupingSeparator = parts.grouping
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSNumber(value: parts.value)) ?? "\(parts.value)"
    }

    /// The number alone, as the Distance filter's readout writes it.
    func distanceValue(_ meters: Double) -> String { written(FormatParts.distance(meters: meters, imperial: imperial)) }

    func distance(_ meters: Double?) -> String {
        guard let meters else { return Self.dash }
        let parts = FormatParts.distance(meters: meters, imperial: imperial)
        return "\(written(parts)) \(unit(parts.unit))"
    }

    func totalDistance(_ meters: Double) -> String {
        let parts = FormatParts.totalDistance(meters: meters, imperial: imperial)
        return "\(written(parts)) \(unit(parts.unit))"
    }

    func duration(_ seconds: Int?) -> String {
        guard let seconds else { return Self.dash }
        switch FormatParts.duration(seconds: seconds) {
        case .hoursMinutes(let h, let m): return String(localized: "\(h)h \(m)m", comment: "A duration in hours and minutes.")
        case .minutes(let m): return String(localized: "\(m)m", comment: "A duration in minutes.")
        case .seconds(let s): return String(localized: "\(s)s", comment: "A duration in seconds.")
        }
    }

    func count(_ n: Int) -> String { NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal) }

    /// Pace on foot ("8:47 /mi"), speed otherwise ("17.1 km/h"); a dash with no distance or time.
    func paceOrSpeed(_ kind: ActivityKind, meters: Double?, seconds: Int?) -> String {
        let unitMeters = imperial ? Pace.metersPerMile : 1000
        if kind.showsPace {
            guard let perUnit = Pace.secondsPerUnit(meters: meters, seconds: seconds, unitMeters: unitMeters) else { return Self.dash }
            return "\(Pace.format(perUnit)) /\(unit)"
        }
        guard let speed = Pace.speed(meters: meters, seconds: seconds, unitMeters: unitMeters) else { return Self.dash }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        let number = formatter.string(from: NSNumber(value: speed)) ?? "\(speed)"
        return imperial ? String(localized: "\(number) mph", comment: "A speed in miles an hour.") : String(localized: "\(number) km/h", comment: "A speed in kilometres an hour.")
    }

    /// "Oct 11, 2026, 9:39 AM", in the zone the activity was recorded in.
    func startedAt(_ activity: Activity) -> String { moment(activity.startedAt, zone: activity.timezone) }

    /// An ISO 8601 moment as "Oct 11, 2026, 9:39 AM", in zone, else the account's (ActivityZone).
    func moment(_ iso: String, zone: String) -> String {
        guard let date = Self.iso(iso) else { return iso }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        if let zone = ActivityZone.of(own: zone, account: accountZone) { formatter.timeZone = TimeZone(identifier: zone) }
        return formatter.string(from: date)
    }

    /// A moment, in epoch seconds, as a time of day ("9:39 AM") in zone, else the account's.
    func clock(_ seconds: Double, zone: String) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        if let zone = ActivityZone.of(own: zone, account: accountZone) { formatter.timeZone = TimeZone(identifier: zone) }
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    /// A row's first line: its name, else its start.
    func label(_ activity: Activity) -> String { activity.title ?? startedAt(activity) }

    /// "Activities: 6 · 74.8 km · 9h 6m".
    func summary(count: Int, meters: Double, seconds: Int) -> String {
        [activityCount(count), totalDistance(meters), duration(seconds)].joined(separator: " · ")
    }

    func activityCount(_ n: Int) -> String { String(localized: "Activities: \(count(n))", comment: "A count of activities, written as label: N.") }

    private static func iso(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}

/// The account's activity types, as the server describes them (ActivityTypeCatalog), for every
/// screen at once; a change is announced so rows drawn with a fallback label redraw.
@MainActor
final class ActivityTypes {
    static let shared = ActivityTypes()
    static let changed = Notification.Name("ActivityTypes.changed")

    private(set) var catalog = ActivityTypeCatalog()
    private var catalogRead = false

    func kind(_ type: String) -> ActivityKind { catalog.kind(type) }
    func label(_ type: String) -> String { catalog.label(type) }

    func merge(_ described: [String: ActivityTypeInfo]) {
        if catalog.merge(described) { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    /// Asks for the catalog and any of types without a label, unless the catalog was read this
    /// run and every one is known.
    func refresh(_ types: [String], api: APIClient) {
        let missing = catalog.missing(types)
        guard !catalogRead || !missing.isEmpty else { return }
        Task {
            guard let described = try? await api.activityTypes(missing) else { return }
            catalogRead = true
            merge(described)
        }
    }

    /// Every type the catalog knows, by label.
    var known: [String] { catalog.labels.keys.sorted { label($0) < label($1) } }

    static func icon(_ kind: ActivityKind) -> UIImage {
        switch kind {
        case .foot: UIImage(resource: .footprints)
        case .wheels: UIImage(resource: .bike)
        case .motor: UIImage(resource: .car)
        case .solowheel: UIImage(resource: .monowheel)
        case .eScooter: UIImage(resource: .electricScooter)
        case .other: UIImage(resource: .route)
        }
    }
}