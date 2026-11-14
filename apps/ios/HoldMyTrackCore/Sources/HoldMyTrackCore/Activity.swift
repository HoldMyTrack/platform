import Foundation

/// An activity as the Activities panel lists it (root docs/SPEC.md FR-5.1).
public struct Activity: Equatable, Sendable {
    public let id: String
    /// ISO 8601, as the server sends it; formatted in timezone (ActivityZone).
    public let startedAt: String
    public let timezone: String
    public let activityType: String
    public let name: String?
    public let distanceMeters: Double?
    public let movingSeconds: Int?
    public let description: String?
    /// `[west, south, east, north]`, or nil with no track.
    public let bbox: [Double]?
    public let pending: Bool
    public let isPrivate: Bool
    public let stories: [StoryRef]
    /// Why its track can't be edited, or nil when it can: the server's code (EditAvailability).
    public let trackEdit: String?
    /// Why photos can't be added to it, or nil when they can.
    public let photosBlock: String?

    public init(
        id: String, startedAt: String, timezone: String = "", activityType: String, name: String? = nil,
        distanceMeters: Double? = nil, movingSeconds: Int? = nil, description: String? = nil, bbox: [Double]? = nil,
        pending: Bool = false, isPrivate: Bool = false, stories: [StoryRef] = [], trackEdit: String? = nil, photosBlock: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.timezone = timezone
        self.activityType = activityType
        self.name = name
        self.distanceMeters = distanceMeters
        self.movingSeconds = movingSeconds
        self.description = description
        self.bbox = bbox
        self.pending = pending
        self.isPrivate = isPrivate
        self.stories = stories
        self.trackEdit = trackEdit
        self.photosBlock = photosBlock
    }

    init(_ json: ActivityRowJSON) {
        self.init(
            id: json.id, startedAt: json.startedAt, timezone: json.timezone, activityType: json.activityType, name: json.name,
            distanceMeters: json.distanceMeters, movingSeconds: json.movingSeconds, description: json.description,
            bbox: json.bbox?.count == 4 ? json.bbox : nil, pending: json.pending, isPrivate: json.private,
            stories: json.stories.map { StoryRef(id: $0.id, name: $0.name) }, trackEdit: json.trackEdit, photosBlock: json.photos
        )
    }

    /// An area list's row: what the Edit window needs besides, it reads in full (APIClient.activity).
    init(_ json: AreaActivityRowJSON) {
        self.init(
            id: json.id, startedAt: json.startedAt, timezone: json.timezone, activityType: json.activityType, name: json.name,
            distanceMeters: json.distanceMeters, movingSeconds: json.movingSeconds,
            bbox: json.bbox?.count == 4 ? json.bbox : nil, pending: json.pending, isPrivate: json.private,
            stories: json.stories.map { StoryRef(id: $0.id, name: $0.name) }
        )
    }

    /// What the panel's rules read of it.
    public var summary: ActivitySummary {
        ActivitySummary(id: id, activityType: activityType, distanceMeters: distanceMeters, isPrivate: isPrivate, isPending: pending)
    }

    /// The name, when it has one that isn't blank.
    public var title: String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name
    }
}

/// A Story an activity is in, as its row's badge names it.
public struct StoryRef: Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A count, a distance and a moving time: a Story's, or one type's share of it.
public struct StoryTotals: Equatable, Sendable {
    /// Empty for the whole Story.
    public let activityType: String
    public let count: Int
    public let distanceMeters: Double
    public let movingSeconds: Int
}

/// A Story (root docs/SPEC.md FR-13): a named set of activities, whatever their dates.
public struct Story: Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    /// Who sent it, for a copy accepted from someone else (FR-13.7).
    public let from: String?
    public let activityIDs: [String]
    public let stats: StoryTotals
    public let byType: [StoryTotals]

    init(_ json: StoryJSON) {
        id = json.id
        name = json.name
        description = json.description ?? ""
        from = json.from
        activityIDs = json.activityIDs
        stats = StoryTotals(activityType: "", count: json.stats.count, distanceMeters: json.stats.distanceMeters, movingSeconds: json.stats.movingSeconds)
        byType = json.stats.byType.map {
            StoryTotals(activityType: $0.activityType, count: $0.count, distanceMeters: $0.distanceMeters, movingSeconds: $0.movingSeconds)
        }
    }

    /// The type labels the Story's numbers carry, for ActivityTypeCatalog.
    static func labels(_ json: StoryJSON) -> [String: ActivityTypeInfo] {
        Dictionary(json.stats.byType.compactMap { t in t.label.flatMap { $0.isEmpty ? nil : (t.activityType, ActivityTypeInfo(kind: nil, label: $0)) } },
                   uniquingKeysWith: { a, _ in a })
    }
}

/// A copy of a Story someone sent, waiting to be accepted or declined (FR-13.7).
public struct StorySend: Equatable, Sendable {
    public let id: String
    public let storyName: String
    public let from: String
    public let activityCount: Int
}

/// An accepted copy still arriving.
public struct StoryCopying: Equatable, Sendable {
    public let storyName: String
    public let from: String
}

public struct StoryInbox: Equatable, Sendable {
    public let sends: [StorySend]
    public let copying: [StoryCopying]
}

/// What the server says about one activity type; either part may be missing.
public struct ActivityTypeInfo: Equatable, Sendable {
    public let kind: ActivityKind?
    public let label: String?

    public init(kind: ActivityKind?, label: String?) {
        self.kind = kind
        self.label = label
    }

    init(_ json: ActivityTypeJSON) {
        self.init(kind: ActivityKind(wire: json.kind), label: json.label.isEmpty ? nil : json.label)
    }
}

/// What kind of moving an activity type is, as the server says (root docs/SPEC.md FR-5.1): its
/// icon, and pace or speed.
public enum ActivityKind: String, Equatable, Sendable, CaseIterable {
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
        self = ActivityKind(rawValue: wire) ?? .other
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