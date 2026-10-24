import Foundation

/// One point of a track: where, and when in Unix milliseconds.
public struct TrackPoint: Equatable, Sendable {
    public let lon: Double
    public let lat: Double
    public let t: Int

    public init(lon: Double, lat: Double, t: Int) {
        self.lon = lon
        self.lat = lat
        self.t = t
    }
}

/// A span of times, both ends inclusive.
public struct TimeSpan: Equatable, Sendable {
    public let from: Int
    public let to: Int

    public init(_ from: Int, _ to: Int) {
        self.from = from
        self.to = to
    }
}

/// The edit the server stores for a track (root docs/IMPLEMENTATION.md §4.7.7), by timestamp:
/// keep one span, remove others, drop single points, move points elsewhere.
public struct TrackEdit: Equatable, Sendable {
    public var keep: TimeSpan?
    public var remove: [TimeSpan] = []
    public var drop: [Int] = []
    /// A point's new lon and lat, by its time.
    public var move: [Int: [Double]] = [:]

    public init(keep: TimeSpan? = nil, remove: [TimeSpan] = [], drop: [Int] = [], move: [Int: [Double]] = [:]) {
        self.keep = keep
        self.remove = remove
        self.drop = drop
        self.move = move
    }

    public var isEmpty: Bool { keep == nil && remove.isEmpty && drop.isEmpty && move.isEmpty }
}

/// One step of an Edit track session.
public enum EditOp: Equatable, Sendable {
    /// Keep only the points from one time to another (inclusive): the Chop button.
    case chop(keep: TimeSpan)
    /// Remove the points between two knobs, keeping both knob points: the Cut button.
    case cut(remove: TimeSpan)
    /// Remove one point: a tap in Delete point mode.
    case drop(t: Int)
    /// Put one point somewhere else: a drag in Move point mode.
    case move(t: Int, lon: Double, lat: Double)
    /// Discard every earlier edit, including the one saved before this session.
    case reset
    /// Split the activity in two at one point (§4.7.8). Not part of the edit: Save sends it beside
    /// the folded edit, which then applies to both pieces.
    case split(t: Int)
}

/// The Edit track session's history. A session is the edit the track already had when the
/// editor opened (base) plus a stack of ops committed since. What the map shows is always a
/// replay of the whole stack on top of the original points, never a mutated copy: Undo pops one
/// op, Cancel drops the stack, and Apply folds it into the one TrackEdit the server stores.
/// Every op addresses points by time, as the server's edit does, so the fold is collecting them.
public enum EditTrackOps {
    /// Folds base and the op stack into one edit; an unedited track folds to an empty one.
    public static func fold(_ base: TrackEdit?, _ ops: [EditOp]) -> TrackEdit {
        var edit = base ?? TrackEdit()
        for op in ops {
            switch op {
            case .reset: edit = TrackEdit()
            case .chop(let keep):
                edit.keep = edit.keep.map { TimeSpan(max($0.from, keep.from), min($0.to, keep.to)) } ?? keep
            case .cut(let remove): edit.remove.append(remove)
            case .drop(let t): edit.drop.append(t)
            // A point dragged twice ends where it was dropped last.
            case .move(let t, let lon, let lat): edit.move[t] = [lon, lat]
            case .split: break
            }
        }
        return edit
    }

    /// The points that survive edit, in order, moved where it moves them: the same as the
    /// server's, so what the editor shows is exactly what Apply will produce.
    public static func apply(_ points: [TrackPoint], _ edit: TrackEdit) -> [TrackPoint] {
        if edit.isEmpty { return points }
        let drop = Set(edit.drop)
        return points.filter { p in
            if let keep = edit.keep, p.t < keep.from || p.t > keep.to { return false }
            if drop.contains(p.t) { return false }
            return !edit.remove.contains { p.t >= $0.from && p.t <= $0.to }
        }.map { p in
            guard let to = edit.move[p.t] else { return p }
            return TrackPoint(lon: to[0], lat: to[1], t: p.t)
        }
    }

    /// The op a Move point drag commits: the point at t dropped at lon and lat, rounded to the
    /// 1e-6° (about 0.1 m) the server sends points in. Halves round up, as the web's Math.round.
    public static func move(t: Int, lon: Double, lat: Double) -> EditOp {
        func round(_ v: Double) -> Double { (v * 1e6 + 0.5).rounded(.down) / 1e6 }
        return .move(t: t, lon: round(lon), lat: round(lat))
    }

    /// The op a Chop press commits for knobs on visible[lo] and visible[hi], or nil when the
    /// knobs sit on both ends and there's nothing to chop.
    public static func chop(_ visible: [TrackPoint], lo: Int, hi: Int) -> EditOp? {
        if lo <= 0 && hi >= visible.count - 1 { return nil }
        if hi - lo < 1 { return nil } // a track needs two points to stay a track
        return .chop(keep: TimeSpan(visible[lo].t, visible[hi].t))
    }

    /// The op a Cut press commits: removes every point strictly between the knobs, so the two
    /// knob points survive and are joined. nil when there's nothing between them.
    public static func cut(_ visible: [TrackPoint], lo: Int, hi: Int) -> EditOp? {
        if hi - lo < 2 { return nil }
        return .cut(remove: TimeSpan(visible[lo + 1].t, visible[hi - 1].t))
    }

    /// The point the session splits the activity at, or nil: at most one split per session.
    public static func splitPoint(_ ops: [EditOp]) -> Int? {
        for case .split(let t) in ops { return t }
        return nil
    }

    /// The index the Split button would split visible at: the one knob moved off its end, as long
    /// as it leaves two points on each side (the point itself counting on both). nil with both
    /// knobs at the ends, or both moved: a split is one point, not a range.
    public static func splitIndex(_ visible: [TrackPoint], lo: Int, hi: Int) -> Int? {
        let last = visible.count - 1
        let at: Int? = lo > 0 && hi >= last ? lo : lo <= 0 && hi < last ? hi : nil
        guard let at, at >= 1, at <= last - 1 else { return nil }
        return at
    }

    /// Cumulative walked distance in meters at each point: the slider's readout.
    public static func cumulativeDistances(_ points: [TrackPoint]) -> [Double] {
        var out: [Double] = []
        var acc = 0.0
        for i in points.indices {
            if i > 0 { acc += haversine(points[i - 1], points[i]) }
            out.append(acc)
        }
        return out
    }

    private static let earthRadius = 6371008.8

    private static func haversine(_ a: TrackPoint, _ b: TrackPoint) -> Double {
        let toRad = Double.pi / 180
        let dLat = (b.lat - a.lat) * toRad
        let dLon = (b.lon - a.lon) * toRad
        let h = pow(sin(dLat / 2), 2) + cos(a.lat * toRad) * cos(b.lat * toRad) * pow(sin(dLon / 2), 2)
        return 2 * earthRadius * asin(min(1, h.squareRoot()))
    }
}
