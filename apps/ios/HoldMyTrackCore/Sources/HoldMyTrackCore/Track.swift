import Foundation

/// A track as the Tracks panel lists it (root docs/SPEC.md FR-5.1).
public struct Track: Equatable, Sendable {
    public let id: String
    /// ISO 8601, as the server sends it; formatted in timezone (TrackZone).
    public let startedAt: String
    public let timezone: String
    public let trackType: String
    public let name: String?
    public let distanceMeters: Double?
    public let movingSeconds: Int?
    public let description: String?
    /// `[west, south, east, north]`; a Private track's is its location's circle's, nil while it is listed under none.
    public let bbox: [Double]?
    public let pending: Bool
    public let isPrivate: Bool
    public let trips: [TripRef]
    /// Why its track can't be edited, or nil when it can: the server's code (EditAvailability).
    public let routeEdit: String?
    /// Why photos can't be added to it, or nil when they can.
    public let photosBlock: String?

    public init(
        id: String, startedAt: String, timezone: String = "", trackType: String, name: String? = nil,
        distanceMeters: Double? = nil, movingSeconds: Int? = nil, description: String? = nil, bbox: [Double]? = nil,
        pending: Bool = false, isPrivate: Bool = false, trips: [TripRef] = [], routeEdit: String? = nil, photosBlock: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.timezone = timezone
        self.trackType = trackType
        self.name = name
        self.distanceMeters = distanceMeters
        self.movingSeconds = movingSeconds
        self.description = description
        self.bbox = bbox
        self.pending = pending
        self.isPrivate = isPrivate
        self.trips = trips
        self.routeEdit = routeEdit
        self.photosBlock = photosBlock
    }

    init(_ json: TrackRowJSON) {
        self.init(
            id: json.id, startedAt: json.startedAt, timezone: json.timezone, trackType: json.trackType, name: json.name,
            distanceMeters: json.distanceMeters, movingSeconds: json.movingSeconds, description: json.description,
            bbox: json.bbox?.count == 4 ? json.bbox : nil, pending: json.pending, isPrivate: json.private,
            trips: json.trips.map { TripRef(id: $0.id, name: $0.name) }, routeEdit: json.routeEdit, photosBlock: json.photos
        )
    }

    /// An area list's row: what the Edit window needs besides, it reads in full (APIClient.track).
    init(_ json: AreaTrackRowJSON) {
        self.init(
            id: json.id, startedAt: json.startedAt, timezone: json.timezone, trackType: json.trackType, name: json.name,
            distanceMeters: json.distanceMeters, movingSeconds: json.movingSeconds,
            bbox: json.bbox?.count == 4 ? json.bbox : nil, pending: json.pending, isPrivate: json.private,
            trips: json.trips.map { TripRef(id: $0.id, name: $0.name) }
        )
    }

    /// What the panel's rules read of it.
    public var summary: TrackSummary {
        TrackSummary(id: id, trackType: trackType, distanceMeters: distanceMeters, isPrivate: isPrivate, isPending: pending)
    }

    /// The name, when it has one that isn't blank.
    public var title: String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name
    }
}

/// A Trip a track is in, as its row's badge names it.
public struct TripRef: Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A count, a distance and a moving time: a Trip's, or one type's share of it.
public struct TripTotals: Equatable, Sendable {
    /// Empty for the whole Trip.
    public let trackType: String
    public let count: Int
    public let distanceMeters: Double
    public let movingSeconds: Int
}

/// A Trip (root docs/SPEC.md FR-13): a named set of tracks, whatever their dates.
public struct Trip: Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    /// Who sent it, for a copy accepted from someone else (FR-13.7).
    public let from: String?
    public let trackIDs: [String]
    public let stats: TripTotals
    public let byType: [TripTotals]

    init(_ json: TripJSON) {
        id = json.id
        name = json.name
        description = json.description ?? ""
        from = json.from
        trackIDs = json.trackIDs
        stats = TripTotals(trackType: "", count: json.stats.count, distanceMeters: json.stats.distanceMeters, movingSeconds: json.stats.movingSeconds)
        byType = json.stats.byType.map {
            TripTotals(trackType: $0.trackType, count: $0.count, distanceMeters: $0.distanceMeters, movingSeconds: $0.movingSeconds)
        }
    }

    /// The type labels the Trip's numbers carry, for TrackTypeCatalog.
    static func labels(_ json: TripJSON) -> [String: TrackTypeInfo] {
        Dictionary(json.stats.byType.compactMap { t in t.label.flatMap { $0.isEmpty ? nil : (t.trackType, TrackTypeInfo(kind: nil, label: $0)) } },
                   uniquingKeysWith: { a, _ in a })
    }
}

/// A copy of a Trip someone sent, waiting to be accepted or declined (FR-13.7).
public struct TripSend: Equatable, Sendable {
    public let id: String
    public let tripName: String
    public let from: String
    public let trackCount: Int
}

/// An accepted copy still arriving.
public struct TripCopying: Equatable, Sendable {
    public let tripName: String
    public let from: String
}

public struct TripInbox: Equatable, Sendable {
    public let sends: [TripSend]
    public let copying: [TripCopying]
}

/// What the server says about one track type; either part may be missing.
public struct TrackTypeInfo: Equatable, Sendable {
    public let kind: TrackKind?
    public let label: String?

    public init(kind: TrackKind?, label: String?) {
        self.kind = kind
        self.label = label
    }

    init(_ json: TrackTypeJSON) {
        self.init(kind: TrackKind(wire: json.kind), label: json.label.isEmpty ? nil : json.label)
    }
}

/// What kind of moving a track type is, as the server says (root docs/SPEC.md FR-5.1): its
/// icon, and pace or speed.
public enum TrackKind: String, Equatable, Sendable, CaseIterable {
    /// Walking, hiking, running: pace.
    case foot
    /// Cycling, skating: speed.
    case wheels
    /// Driving, motorcycling: speed.
    case motor
    case solowheel
    case eScooter = "e_scooter"
    /// Everything else, and a kind from a newer server: speed, the safer reading.
    case other

    public init(wire: String) {
        self = TrackKind(rawValue: wire) ?? .other
    }

    /// Pace reads naturally only on foot.
    public var showsPace: Bool { self == .foot }
}

/// Pace and speed from a distance and a moving time, in a unit unitMeters long (a km or a mile).
public enum Pace {
    public static let metersPerMile = 1609.344

    /// Seconds per unit, or nil with no distance or no time.
    public static func secondsPerUnit(meters: Double?, seconds: Int?, unitMeters: Double) -> Double? {
        guard let meters, let seconds, meters > 0, seconds > 0 else { return nil }
        return Double(seconds) / (meters / unitMeters)
    }

    /// "5:27": minutes and seconds, a halfway second rounding up.
    public static func format(_ secondsPerUnit: Double) -> String {
        let total = Int((secondsPerUnit + 0.5).rounded(.down))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    /// Units per hour, or nil with no distance or no time.
    public static func speed(meters: Double?, seconds: Int?, unitMeters: Double) -> Double? {
        guard let meters, let seconds, meters > 0, seconds > 0 else { return nil }
        return (meters / unitMeters) / (Double(seconds) / 3600)
    }
}