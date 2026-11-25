import Foundation

/// Whether a recording runs: idle, recording, or paused.
public enum RecordingState: String, Codable, Sendable { case idle, recording, paused }

/// One fix of a recording: where, how high if known, and when.
public struct RecordedPoint: Codable, Equatable, Sendable {
    public let lat: Double
    public let lon: Double
    public let ele: Double?
    public let time: Date

    public init(lat: Double, lon: Double, ele: Double?, time: Date) {
        self.lat = lat
        self.lon = lon
        self.ele = ele
        self.time = time
    }
}

/// What the phone allows for recording, as CoreLocation reports it.
public enum RecordingAccess: Sendable {
    case notAsked, denied, approximate, precise
}

/// What a tap on the record button does (apps/ios/docs/SPEC.md FR-5.1): recording pauses; idle
/// starts and paused resumes, each once precise location is allowed, so a leftover can't resume
/// without it. A tap never stops: that takes a hold.
public enum RecordTap: Equatable, Sendable {
    case start, pause, resume
    /// Ask for location while in use, or for precise location this once.
    case askLocation, askPrecise
    /// Location is off for the app: Settings can turn it on.
    case refused

    public static func of(_ state: RecordingState, access: RecordingAccess) -> RecordTap {
        if state == .recording { return .pause }
        switch access {
        case .notAsked: return .askLocation
        case .denied: return .refused
        case .approximate: return .askPrecise
        case .precise: return state == .paused ? .resume : .start
        }
    }
}

/// A recording in progress, as values (apps/android/docs/SPEC.md FR-5.1): its fixes, its moving
/// time with pauses left out, and its distance, none of it across a pause. The first fix after a
/// pause is a fresh baseline, not a jump from wherever the phone was when it paused.
public struct Recording: Equatable, Sendable {
    /// The recording's id from its start: the journal's, and the saved file's.
    public private(set) var id = ""
    public private(set) var state: RecordingState = .idle
    public private(set) var points: [RecordedPoint] = []
    public private(set) var startedAt: Date?
    /// Moving time up to the last pause; the run since then counts from runningSince.
    public private(set) var movedBefore: TimeInterval = 0
    public private(set) var runningSince: Date?
    public private(set) var meters: Double = 0
    /// The fix the next one's step is measured from; nil after a pause.
    private var last: RecordedPoint?

    /// A stop shorter than this, moving time with pauses left out, keeps nothing: an accidental
    /// tap, not a track anyone meant to keep. Android's.
    public static let minimumMoving: TimeInterval = 60
    /// The hold on the button that stops.
    public static let holdToStop: TimeInterval = 2
    /// Fixes closer in time than this to the last kept one are dropped, as Android asks its GPS
    /// for one every 3 seconds.
    public static let minimumInterval: TimeInterval = 3
    /// A fix nearer than this to the last kept one is dropped, Android's: a phone standing still
    /// would add points and distance.
    public static let minimumStep: Double = 5
    /// Fixes vaguer than this are dropped: iOS has no GPS-only provider, and a position from Wi-Fi
    /// or cell towers would draw a jump.
    public static let worstAccuracy: Double = 50

    public init() {}

    public mutating func start(at now: Date, id: String = UUID().uuidString.lowercased()) {
        self = Recording()
        self.id = id
        state = .recording
        startedAt = now
        runningSince = now
    }

    /// A recording the app died in, picked up paused where it was: the time it was dead adds no
    /// moving time, and the next fix starts afresh.
    public static func restored(_ leftover: RecordingJournal.Leftover) -> Recording {
        var recording = Recording()
        recording.id = leftover.id
        recording.state = .paused
        recording.startedAt = leftover.startedAt
        recording.movedBefore = leftover.moving
        recording.meters = leftover.meters
        recording.points = leftover.points
        return recording
    }

    public mutating func pause(at now: Date) {
        guard state == .recording else { return }
        movedBefore += now.timeIntervalSince(runningSince ?? now)
        runningSince = nil
        last = nil
        state = .paused
    }

    public mutating func resume(at now: Date) {
        guard state == .paused else { return }
        runningSince = now
        state = .recording
    }

    /// Moving time at now: every run between a start or resume and a pause.
    public func moving(at now: Date) -> TimeInterval {
        movedBefore + (runningSince.map { now.timeIntervalSince($0) } ?? 0)
    }

    /// Whether a fix of accuracy metres (negative when CoreLocation couldn't tell) taken at time
    /// is kept: only while recording, taken since the start or resume (CoreLocation hands over its
    /// last cached fix first, which may be far away and long ago), accurate enough, and not too
    /// soon after the last kept one.
    public func accepts(accuracy: Double, at time: Date) -> Bool {
        guard state == .recording, accuracy >= 0, accuracy <= Self.worstAccuracy else { return false }
        if let runningSince, time < runningSince { return false }
        guard let last else { return true }
        return time.timeIntervalSince(last.time) >= Self.minimumInterval
    }

    /// Keeps point if accepts says so and it's minimumStep on, adding its step from the fix before; true when kept.
    @discardableResult
    public mutating func add(_ point: RecordedPoint, accuracy: Double) -> Bool {
        guard accepts(accuracy: accuracy, at: point.time) else { return false }
        if let last {
            let step = Self.distance(last, point)
            guard step >= Self.minimumStep else { return false }
            meters += step
        }
        last = point
        points.append(point)
        return true
    }

    /// What Stop keeps at now: the finished recording, or nil for one too short to keep, at least
    /// a minute of moving time and two points to draw a line between.
    public func finished(at now: Date, type: String) -> RecordedTrack? {
        let moved = moving(at: now)
        guard let startedAt, moved >= Self.minimumMoving, points.count >= 2 else { return nil }
        return RecordedTrack(id: id, startedAt: startedAt, endedAt: now, movingSeconds: moved, meters: meters, type: type, points: points)
    }

    /// The great-circle distance between two fixes, in metres.
    static func distance(_ a: RecordedPoint, _ b: RecordedPoint) -> Double {
        let rad = Double.pi / 180
        let h = pow(sin((b.lat - a.lat) * rad / 2), 2) + cos(a.lat * rad) * cos(b.lat * rad) * pow(sin((b.lon - a.lon) * rad / 2), 2)
        return 2 * 6_371_008.8 * asin(min(1, h.squareRoot()))
    }
}

/// What the recording's status over the map says, as values, Android's: nothing while idle, else
/// the moving time over the distance, over "Paused" with it while paused, or over waiting for the
/// first fix.
public enum RecordingStatus: Equatable, Sendable {
    case none
    case waiting(moving: TimeInterval)
    case paused(moving: TimeInterval, meters: Double)
    case running(moving: TimeInterval, meters: Double)

    public static func of(_ recording: Recording, at now: Date) -> RecordingStatus {
        let moving = recording.moving(at: now)
        switch recording.state {
        case .idle: return .none
        case .paused: return .paused(moving: moving, meters: recording.meters)
        case .recording: return recording.points.isEmpty ? .waiting(moving: moving) : .running(moving: moving, meters: recording.meters)
        }
    }

    /// H:MM:SS, as Android's.
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
    }

    /// Whether the record button takes the user to the map, from whichever tab: a start, since
    /// the recording is drawn there, and a stop, whose outcome is said there.
    public static func showsMap(stopping: Bool, state: RecordingState) -> Bool { stopping || state == .idle }
}

/// A stopped recording, kept on the phone under its account (RecordingStore) until it's on the
/// map: its fixes, what Edit sets, and whether it was sent and is awaited (RecordingSync).
public struct RecordedTrack: Codable, Equatable, Sendable {
    public let id: String
    public let startedAt: Date
    public let endedAt: Date
    public let movingSeconds: TimeInterval
    public let meters: Double
    /// The account's last type set in Edit, `unknown` at first.
    public var type: String
    public let points: [RecordedPoint]
    /// Set only by someone typing one.
    public var name: String?
    public var description: String?
    /// The server took it and its ingest hasn't ended: it's listed as on its way meanwhile.
    public var sent: Bool

    public init(id: String, startedAt: Date, endedAt: Date, movingSeconds: TimeInterval, meters: Double, type: String, points: [RecordedPoint],
                name: String? = nil, description: String? = nil, sent: Bool = false) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.movingSeconds = movingSeconds
        self.meters = meters
        self.type = type
        self.points = points
        self.name = name
        self.description = description
        self.sent = sent
    }

    enum CodingKeys: String, CodingKey { case id, startedAt, endedAt, movingSeconds, meters, type, points, name, description, sent }

    /// A file written before a field existed reads it as unset.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), startedAt: try c.decode(Date.self, forKey: .startedAt),
                  endedAt: try c.decode(Date.self, forKey: .endedAt), movingSeconds: try c.decode(TimeInterval.self, forKey: .movingSeconds),
                  meters: try c.decode(Double.self, forKey: .meters), type: try c.decode(String.self, forKey: .type),
                  points: try c.decode([RecordedPoint].self, forKey: .points), name: try c.decodeIfPresent(String.self, forKey: .name),
                  description: try c.decodeIfPresent(String.self, forKey: .description), sent: try c.decodeIfPresent(Bool.self, forKey: .sent) ?? false)
    }
}

/// Stopped recordings on the phone, each account's in a folder of its own (apps/android/docs/SPEC.md
/// FR-5.3), so two accounts on one phone never see each other's, with the account's default type
/// and its hidden Sync rows beside them. A file per recording. Nothing here goes into a device
/// backup.
public struct RecordingStore: Sendable {
    let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The folder for an account key (AccountKey): its hex, so any email is a safe name.
    public func folder(account: String) -> URL {
        root.appending(path: Data(account.utf8).map { String(format: "%02x", $0) }.joined(), directoryHint: .isDirectory)
    }

    public func save(_ track: RecordedTrack, account: String) throws {
        let folder = try made(account)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(track).write(to: folder.appending(path: "\(track.id).json"), options: .atomic)
    }

    /// The account's recordings, oldest first; a file that can't be read is left out.
    public func list(account: String) -> [RecordedTrack] {
        let names = (try? FileManager.default.contentsOfDirectory(at: folder(account: account), includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return names.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(RecordedTrack.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// The account's folder, made if it isn't there, with the store kept out of backups.
    private func made(_ account: String) throws -> URL {
        let folder = folder(account: account)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var base = root
        try? base.setResourceValues(values)
        return folder
    }

    /// The type a new recording gets: the last one set in Edit under the account, `unknown` at first.
    public func defaultType(account: String) -> String {
        (try? String(contentsOf: folder(account: account).appending(path: "type"), encoding: .utf8)) ?? "unknown"
    }

    public func setDefaultType(_ type: String, account: String) {
        guard let folder = try? made(account) else { return }
        try? type.write(to: folder.appending(path: "type"), atomically: true, encoding: .utf8)
    }

    /// One recording, gone for good: the phone's copy is the only one until it's on the map. A
    /// hidden one is forgotten with it, deleted or landed.
    public func delete(id: String, account: String) {
        try? FileManager.default.removeItem(at: folder(account: account).appending(path: "\(id).json"))
        let hidden = hidden(account: account)
        if hidden.contains(id) { setHidden(hidden.subtracting([id]), account: account) }
    }

    /// The Sync rows swiped aside (apps/android/docs/SPEC.md FR-3.5), by recording id. Only a
    /// delete prunes it: a list that failed to read never empties it.
    public func hidden(account: String) -> Set<String> {
        guard let data = try? Data(contentsOf: folder(account: account).appending(path: "hidden")),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(ids)
    }

    public func setHidden(_ ids: Set<String>, account: String) {
        guard let folder = try? made(account), let data = try? JSONEncoder().encode(ids.sorted()) else { return }
        try? data.write(to: folder.appending(path: "hidden"), options: .atomic)
    }

    /// Everything kept for an account, as Delete account leaves nothing on the phone.
    public func forget(account: String) {
        try? FileManager.default.removeItem(at: folder(account: account))
    }
}