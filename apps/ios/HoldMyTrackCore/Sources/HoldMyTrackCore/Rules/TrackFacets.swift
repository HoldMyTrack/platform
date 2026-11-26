import Foundation

/// What the panel's rules read of a listed track.
public struct TrackSummary: Equatable, Sendable {
    public let id: String
    public let trackType: String
    public let distanceMeters: Double?
    public let isPrivate: Bool
    /// Its track is being reprocessed.
    public let isPending: Bool

    public init(id: String, trackType: String, distanceMeters: Double?, isPrivate: Bool, isPending: Bool = false) {
        self.id = id
        self.trackType = trackType
        self.distanceMeters = distanceMeters
        self.isPrivate = isPrivate
        self.isPending = isPending
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

/// One TYPE the listed tracks use, and how many of them do.
public struct TypeFacet: Equatable, Sendable {
    public let type: String
    public let count: Int
}

/// The Tracks panel's two client-side filters, TYPE and DISTANCE (docs/SPEC.md FR-5.2,
/// FR-5.3). Both narrow a list already fetched for the date range; neither is sent to the server.
public enum TrackFacets {
    /// The DISTANCE slider's ends: the shortest and longest track with a distance, or nil
    /// when none has one. A private track has none: its stored 0 is no track, not a short one.
    public static func distanceBounds(_ tracks: [TrackSummary]) -> DistanceRange? {
        let distances = tracks.filter { !$0.isPrivate }.compactMap(\.distanceMeters)
        guard let low = distances.min(), let high = distances.max() else { return nil }
        return DistanceRange(min: low, max: high)
    }

    /// One kilometer or mile, in meters: the DISTANCE filter moves in whole ones.
    static func unitMeters(imperial: Bool) -> Double { imperial ? 1609.344 : 1000 }

    /// meters in units, the floating-point noise of the division taken off, so 10 miles is 10
    /// and not a hair over, which would round up to 11.
    static func inUnits(_ meters: Double, unit: Double) -> Double { (meters / unit * 1e6).rounded() / 1e6 }

    /// The DISTANCE slider's ends (testdata/client-rules/distance-whole-bounds.json): bounds
    /// rounded outward to whole kilometers or miles, so every track lies within them.
    public static func wholeDistanceBounds(_ bounds: DistanceRange?, imperial: Bool) -> DistanceRange? {
        guard let bounds else { return nil }
        let unit = unitMeters(imperial: imperial)
        return DistanceRange(min: inUnits(bounds.min, unit: unit).rounded(.down) * unit, max: inUnits(bounds.max, unit: unit).rounded(.up) * unit)
    }

    /// The DISTANCE filter after knob moved to value, snapped to a whole kilometer or mile
    /// within bounds: the other knob held, the two never crossing, and nil (no filter) once both
    /// are back at bounds, so a knob dragged away and back leaves nothing filtered out.
    public static func nextDistanceFilter(bounds: DistanceRange, current: DistanceRange, knob: DistanceKnob, value: Double, imperial: Bool) -> DistanceRange? {
        let unit = unitMeters(imperial: imperial)
        let snapped = Swift.min(Swift.max(inUnits(value, unit: unit).rounded() * unit, bounds.min), bounds.max)
        let next = switch knob {
        case .min: DistanceRange(min: Swift.min(snapped, current.max), max: current.max)
        case .max: DistanceRange(min: current.min, max: Swift.max(snapped, current.min))
        }
        return next.min <= bounds.min && next.max >= bounds.max ? nil : next
    }

    /// A track with no distance never passes an active band (it can't be placed on it), and
    /// nor does a private one.
    public static func passesDistance(_ track: TrackSummary, _ filter: DistanceRange?) -> Bool {
        guard let filter else { return true }
        guard !track.isPrivate, let meters = track.distanceMeters else { return false }
        return meters >= filter.min && meters <= filter.max
    }

    /// The TYPE dropdown's rows: every type among the tracks the DISTANCE band lets through,
    /// busiest first, ties in the order they're first met. Counted after DISTANCE, not before, so
    /// a count never promises rows the other filter already removed.
    public static func typeFacets(_ tracks: [TrackSummary], distanceFilter: DistanceRange?) -> [TypeFacet] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for track in tracks where passesDistance(track, distanceFilter) {
            if counts[track.trackType] == nil { order.append(track.trackType) }
            counts[track.trackType, default: 0] += 1
        }
        let facets = order.map { TypeFacet(type: $0, count: counts[$0]!) }
        // A stable sort, by index on ties, as the web's and Android's are.
        return facets.enumerated().sorted { a, b in
            a.element.count != b.element.count ? a.element.count > b.element.count : a.offset < b.offset
        }.map(\.element)
    }

    public static func passesFilters(_ track: TrackSummary, excludedTypes: Set<String>, distanceFilter: DistanceRange?) -> Bool {
        !excludedTypes.contains(track.trackType) && passesDistance(track, distanceFilter)
    }
}

/// The zone a track's times are shown in (root docs/IMPLEMENTATION.md §4.30): the one it was
/// recorded in, else the account's, else the phone's. A zone the phone's tz data doesn't know
/// yet falls through to the next rather than failing to format.
public enum TrackZone {
    /// The zone's identifier, or nil for the phone's own.
    public static func of(own: String?, account: String?) -> String? {
        [own, account].lazy.compactMap { $0 }.first { !$0.isEmpty && TimeZone(identifier: $0) != nil }
    }

    /// The day startedAt (RFC 3339) falls on, "2026-11-21", in the zone of(own:account:) picks:
    /// the day the Tracks tab opens a track on. Nil when startedAt doesn't read.
    public static func day(startedAt: String, own: String?, account: String?) -> String? {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = plain.date(from: startedAt) ?? fractional.date(from: startedAt) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = of(own: own, account: account).flatMap(TimeZone.init(identifier:)) ?? .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}

/// The Distance slider's steps: one per whole kilometer or mile between its ends
/// (TrackFacets.wholeDistanceBounds).
public enum DistanceSteps {
    /// How many steps span ends: at least one, so equal ends still draw a slider.
    public static func count(_ ends: DistanceRange, imperial: Bool) -> Int {
        let unit = TrackFacets.unitMeters(imperial: imperial)
        return Swift.max(Int(TrackFacets.inUnits(ends.max - ends.min, unit: unit).rounded()), 1)
    }

    public static func meters(_ step: Int, ends: DistanceRange, imperial: Bool) -> Double {
        let n = count(ends, imperial: imperial)
        if step <= 0 { return ends.min }
        if step >= n { return ends.max }
        return ends.min + Double(step) * TrackFacets.unitMeters(imperial: imperial)
    }

    public static func step(_ meters: Double, ends: DistanceRange, imperial: Bool) -> Int {
        let unit = TrackFacets.unitMeters(imperial: imperial)
        let step = Int(TrackFacets.inUnits(meters - ends.min, unit: unit).rounded())
        return Swift.min(Swift.max(step, 0), count(ends, imperial: imperial))
    }
}
