import Foundation

/// What the panel's rules read of a listed activity.
public struct ActivitySummary: Equatable, Sendable {
    public let id: String
    public let activityType: String
    public let distanceMeters: Double?
    public let isPrivate: Bool

    public init(id: String, activityType: String, distanceMeters: Double?, isPrivate: Bool) {
        self.id = id
        self.activityType = activityType
        self.distanceMeters = distanceMeters
        self.isPrivate = isPrivate
    }
}

/// A DISTANCE band in meters, both ends inclusive.
public struct DistanceRange: Equatable, Sendable {
    public let min: Double
    public let max: Double

    public init(min: Double, max: Double) {
        self.min = min
        self.max = max
    }
}

/// The DISTANCE slider's two knobs.
public enum DistanceKnob: Sendable { case min, max }

/// One TYPE the listed activities use, and how many of them do.
public struct TypeFacet: Equatable, Sendable {
    public let type: String
    public let count: Int
}

/// The Activities panel's two client-side filters, TYPE and DISTANCE (docs/SPEC.md FR-5.2,
/// FR-5.3). Both narrow a list already fetched for the date range; neither is sent to the server.
public enum ActivityFacets {
    /// The DISTANCE slider's ends: the shortest and longest activity with a distance, or nil
    /// when none has one. A private activity has none: its stored 0 is no track, not a short one.
    public static func distanceBounds(_ activities: [ActivitySummary]) -> DistanceRange? {
        let distances = activities.filter { !$0.isPrivate }.compactMap(\.distanceMeters)
        guard let low = distances.min(), let high = distances.max() else { return nil }
        return DistanceRange(min: low, max: high)
    }

    /// The DISTANCE filter after knob moved to value: the other knob held, the two never
    /// crossing, and nil (no filter) once both are back at bounds, so a knob dragged away and
    /// back leaves nothing filtered out.
    public static func nextDistanceFilter(bounds: DistanceRange, current: DistanceRange, knob: DistanceKnob, value: Double) -> DistanceRange? {
        let next = switch knob {
        case .min: DistanceRange(min: Swift.min(value, current.max), max: current.max)
        case .max: DistanceRange(min: current.min, max: Swift.max(value, current.min))
        }
        return next.min <= bounds.min && next.max >= bounds.max ? nil : next
    }

    /// An activity with no distance never passes an active band (it can't be placed on it), and
    /// nor does a private one.
    public static func passesDistance(_ activity: ActivitySummary, _ filter: DistanceRange?) -> Bool {
        guard let filter else { return true }
        guard !activity.isPrivate, let meters = activity.distanceMeters else { return false }
        return meters >= filter.min && meters <= filter.max
    }

    /// The TYPE dropdown's rows: every type among the activities the DISTANCE band lets through,
    /// busiest first, ties in the order they're first met. Counted after DISTANCE, not before, so
    /// a count never promises rows the other filter already removed.
    public static func typeFacets(_ activities: [ActivitySummary], distanceFilter: DistanceRange?) -> [TypeFacet] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for activity in activities where passesDistance(activity, distanceFilter) {
            if counts[activity.activityType] == nil { order.append(activity.activityType) }
            counts[activity.activityType, default: 0] += 1
        }
        let facets = order.map { TypeFacet(type: $0, count: counts[$0]!) }
        // A stable sort, by index on ties, as the web's and Android's are.
        return facets.enumerated().sorted { a, b in
            a.element.count != b.element.count ? a.element.count > b.element.count : a.offset < b.offset
        }.map(\.element)
    }

    public static func passesFilters(_ activity: ActivitySummary, excludedTypes: Set<String>, distanceFilter: DistanceRange?) -> Bool {
        !excludedTypes.contains(activity.activityType) && passesDistance(activity, distanceFilter)
    }
}

/// The zone an activity's times are shown in (root docs/IMPLEMENTATION.md §4.30): the one it was
/// recorded in, else the account's, else the phone's. A zone the phone's tz data doesn't know
/// yet falls through to the next rather than failing to format.
public enum ActivityZone {
    /// The zone's identifier, or nil for the phone's own.
    public static func of(own: String?, account: String?) -> String? {
        [own, account].lazy.compactMap { $0 }.first { !$0.isEmpty && TimeZone(identifier: $0) != nil }
    }
}
