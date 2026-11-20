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

/// What a tap on the record button does (apps/ios/docs/SPEC.md FR-5.1): idle starts once precise
/// location is allowed; recording pauses; paused resumes. A tap never stops: that takes a hold.
public enum RecordTap: Equatable, Sendable {
    case start, pause, resume
    /// Ask for location while in use, or for precise location this once.
    case askLocation, askPrecise
    /// Location is off for the app: Settings can turn it on.
    case refused

    public static func of(_ state: RecordingState, access: RecordingAccess) -> RecordTap {
        switch state {
        case .recording: return .pause
        case .paused: return .resume
        case .idle:
            switch access {
            case .notAsked: return .askLocation
            case .denied: return .refused
            case .approximate: return .askPrecise
            case .precise: return .start
            }
        }
    }
}

/// A recording in progress, as values (apps/android/docs/SPEC.md FR-5.1): its fixes, its moving
/// time with pauses left out, and its distance, none of it across a pause. The first fix after a
/// pause is a fresh baseline, not a jump from wherever the phone was when it paused.
public struct Recording: Equatable, Sendable {
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
    /// Fixes vaguer than this are dropped: iOS has no GPS-only provider, and a position from Wi-Fi
    /// or cell towers would draw a jump.
    public static let worstAccuracy: Double = 50

    public init() {}

    public mutating func start(at now: Date) {
        self = Recording()
        state = .recording
        startedAt = now
        runningSince = now
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
    /// is kept: only while recording, accurate enough, and not too soon after the last kept one.
    public func accepts(accuracy: Double, at time: Date) -> Bool {
        guard state == .recording, accuracy >= 0, accuracy <= Self.worstAccuracy else { return false }
        guard let last else { return true }
        return time.timeIntervalSince(last.time) >= Self.minimumInterval
    }

    /// Keeps point if accepts says so, adding its step from the fix before; true when kept.
    @discardableResult
    public mutating func add(_ point: RecordedPoint, accuracy: Double) -> Bool {
        guard accepts(accuracy: accuracy, at: point.time) else { return false }
        if let last { meters += Self.distance(last, point) }
        last = point
        points.append(point)
        return true
    }

    /// What Stop keeps at now: the finished recording, or nil for one too short to keep, at least
    /// a minute of moving time and two points to draw a line between.
    public func finished(at now: Date, type: String) -> RecordedTrack? {
        let moved = moving(at: now)
        guard let startedAt, moved >= Self.minimumMoving, points.count >= 2 else { return nil }
        return RecordedTrack(id: UUID().uuidString.lowercased(), startedAt: startedAt, endedAt: now, movingSeconds: moved, meters: meters, type: type, points: points)
    }

    /// The great-circle distance between two fixes, in metres.
    static func distance(_ a: RecordedPoint, _ b: RecordedPoint) -> Double {
        let rad = Double.pi / 180
        let h = pow(sin((b.lat - a.lat) * rad / 2), 2) + cos(a.lat * rad) * cos(b.lat * rad) * pow(sin((b.lon - a.lon) * rad / 2), 2)
        return 2 * 6_371_008.8 * asin(min(1, h.squareRoot()))
    }
}

/// A stopped recording, kept on the phone under its account (RecordingStore).
public struct RecordedTrack: Codable, Equatable, Sendable {
    public let id: String
    public let startedAt: Date
    public let endedAt: Date
    public let movingSeconds: TimeInterval
    public let meters: Double
    /// `unknown` until Edit sets one, or the account's last.
    public let type: String
    public let points: [RecordedPoint]
}

/// Stopped recordings on the phone, each account's in a folder of its own (apps/android/docs/SPEC.md
/// FR-5.3), so two accounts on one phone never see each other's. A file per recording.
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
        let folder = folder(account: account)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
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

    /// Everything kept for an account, as Delete account leaves nothing on the phone.
    public func forget(account: String) {
        try? FileManager.default.removeItem(at: folder(account: account))
    }
}