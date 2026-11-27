import Foundation
import HoldMyTrackCore
import UIKit

/// The Tracks panel's numbers and dates in the app's language: FormatParts' decisions
/// written out, a start time as a medium date with a short time in the zone the track was
/// recorded in (TrackZone), units by the account's Country.
@MainActor
struct PanelFormat {
    let imperial: Bool
    /// The account's zone, for a track with none of its own.
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

    /// An end of the Distance filter's band, the number alone (FormatParts.distanceBand).
    func distanceBandValue(_ meters: Double) -> String { written(FormatParts.distanceBand(meters: meters, imperial: imperial)) }

    /// An end of the Distance slider, with its unit.
    func distanceBand(_ meters: Double) -> String {
        let parts = FormatParts.distanceBand(meters: meters, imperial: imperial)
        return "\(written(parts)) \(unit(parts.unit))"
    }

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

    /// A Private location's radius: "200 m", or "656 ft".
    func radius(_ meters: Int) -> String {
        let n = count(PrivateLocation.shown(radiusM: meters, imperial: imperial))
        return imperial ? String(localized: "\(n) ft", comment: "A Private location's radius in feet.") : String(localized: "\(n) m", comment: "A Private location's radius in metres.")
    }

    func count(_ n: Int) -> String { NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal) }

    /// "Oct 11, 2026, 9:39 AM", in the zone the track was recorded in.
    func startedAt(_ track: Track) -> String { moment(track.startedAt, zone: track.timezone) }

    /// An ISO 8601 moment as "Oct 11, 2026, 9:39 AM", in zone, else the account's (TrackZone).
    func moment(_ iso: String, zone: String) -> String {
        guard let date = Self.iso(iso) else { return iso }
        return Self.dateTime(date, zone: TrackZone.of(own: zone, account: accountZone).flatMap(TimeZone.init(identifier:)))
    }

    /// A moment as Android writes it, a medium date and a short time joined by a comma:
    /// "Oct 11, 2026, 9:39 AM", "11 окт. 2026 г., 09:39". iOS's own medium style puts "at"
    /// between them in English. In zone, else the phone's.
    static func dateTime(_ date: Date, zone: TimeZone? = nil) -> String {
        dayFormatter.timeZone = zone ?? .current
        timeFormatter.timeZone = zone ?? .current
        return "\(dayFormatter.string(from: date)), \(timeFormatter.string(from: date))"
    }

    /// Made once: a list formats a moment for every row. Main-thread only, as the screens are.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    /// A moment, in epoch seconds, as a time of day ("9:39 AM") in zone, else the account's.
    func clock(_ seconds: Double, zone: String) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        if let zone = TrackZone.of(own: zone, account: accountZone) { formatter.timeZone = TimeZone(identifier: zone) }
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    /// A row's first line: its name, else its start.
    func label(_ track: Track) -> String { track.title ?? startedAt(track) }

    /// "Tracks: 6 · 74.8 km · 9h 6m".
    func summary(count: Int, meters: Double, seconds: Int) -> String {
        [trackCount(count), totalDistance(meters), duration(seconds)].joined(separator: " · ")
    }

    /// "6 tracks", "1,234 tracks", as Android counts them: the count grouped, the plural from n.
    func trackCount(_ n: Int) -> String {
        String(localized: "panel.trackCount", defaultValue: "\(n) \(count(n)) tracks", comment: "A count of tracks: the number for the plural, then the number as written.")
    }

    /// The Tracks tab's footer: "2 checked · 12.4 km", the toolbar's target and its distance.
    func checkedFooter(count: Int, meters: Double) -> String {
        String(localized: "panel.footer", defaultValue: "\(self.count(count)) checked · \(totalDistance(meters))", comment: "The Tracks tab's footer: how many tracks the toolbar acts on, and their distance.")
    }

    private static func iso(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}

/// The account's track types, as the server describes them (TrackTypeCatalog), for every
/// screen at once; a change is announced so rows drawn with a fallback label redraw.
@MainActor
final class TrackTypes {
    static let shared = TrackTypes()
    static let changed = Notification.Name("TrackTypes.changed")

    private(set) var catalog = TrackTypeCatalog()
    private var catalogRead = false

    func kind(_ type: String) -> TrackKind { catalog.kind(type) }
    func label(_ type: String) -> String { catalog.label(type) }

    func merge(_ described: [String: TrackTypeInfo]) {
        if catalog.merge(described) { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    /// Asks for the catalog and any of types without a label, unless the catalog was read this
    /// run and every one is known.
    func refresh(_ types: [String], api: APIClient) {
        guard let missing = catalog.toRead(types, catalogRead: catalogRead) else { return }
        Task {
            guard let described = try? await api.trackTypes(missing) else { return }
            catalogRead = true
            merge(described)
        }
    }

    /// Every type the catalog knows, by label.
    var known: [String] { catalog.labels.keys.sorted { label($0) < label($1) } }

    static func icon(_ kind: TrackKind) -> UIImage {
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