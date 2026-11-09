import Foundation

/// Why the Edit window's Track or Photos tab can't be used.
public enum EditBlock: Equatable, Sendable { case checkOne, pending, isPrivate, noOriginal, badTimes }

/// Whether the Track and Photos tabs can be used for the Edit window's activities, Android's and
/// the web's EditAvailability. One activity's answer is the server's (the list's `track_edit` and
/// `photos`, root docs/SPEC.md FR-5.14 and FR-16.1); the app adds only the rule that depends on
/// the selection: one activity.
public enum EditAvailability {
    public static func track(_ group: [Activity]) -> EditBlock? {
        guard group.count == 1 else { return .checkOne }
        return block(group[0].trackEdit)
    }

    public static func photos(_ group: [Activity]) -> EditBlock? {
        guard group.count == 1 else { return .checkOne }
        return block(group[0].photosBlock)
    }

    /// A code the app doesn't know, from a newer server, is left to the server to refuse.
    static func block(_ code: String?) -> EditBlock? {
        switch code {
        case "pending": .pending
        case "private": .isPrivate
        case "no_original": .noOriginal
        case "bad_times": .badTimes
        default: nil
        }
    }
}

/// What the editor's overlay previews: what's outside the knobs going (Chop, the default), what's
/// between them (Cut, while its button is held), or the track in two at a knob (Split, held).
public enum EditPreview: Equatable, Sendable { case chop, cut, split }

/// One Edit track session (root docs/SPEC.md FR-5.14, FR-5.17), Android's TrackEditor less its
/// views: the recorded points, the edit saved on them, the steps taken since, and the two knobs.
/// The knobs are held as the times of the points they sit on, not as indices, so a deleted point
/// elsewhere never moves them; nil is "at that end". Split is a step, so Undo takes it back, but
/// it isn't part of the edit: Save sends splitAt beside it. One split a session; once it's made
/// the other tools wait for Undo, since the edit applies to both parts.
public struct TrackEditSession: Equatable, Sendable {
    public let points: [TrackPoint]
    public let base: TrackEdit?
    public private(set) var ops: [EditOp] = []
    public private(set) var knobLo: Int?
    public private(set) var knobHi: Int?

    public init(points: [TrackPoint], base: TrackEdit?) {
        self.points = points
        self.base = base
    }

    /// The points as the session's edit leaves them.
    public var visible: [TrackPoint] { EditTrackOps.apply(points, EditTrackOps.fold(base, ops)) }

    /// Whether the session changed anything: what Save sends, and the tab's dot.
    public var changed: Bool { !ops.isEmpty }

    /// The whole edit to send, nil to go back to the track as recorded.
    public var pending: TrackEdit? {
        let edit = EditTrackOps.fold(base, ops)
        return edit.isEmpty ? nil : edit
    }

    /// The time to split the activity at, sent beside pending.
    public var splitAt: Int? { EditTrackOps.splitPoint(ops) }

    /// Whether Reset has anything to take back.
    public var canReset: Bool { !EditTrackOps.fold(base, ops).isEmpty && splitAt == nil }

    /// The knobs' indices in visible: the first point at or after the low knob's time, the last
    /// at or before the high one's.
    public func knobs(in visible: [TrackPoint]) -> (lo: Int, hi: Int) {
        let last = visible.count - 1
        let lo = knobLo.map { t in visible.firstIndex { $0.t >= t } ?? 0 } ?? 0
        let found = knobHi.map { t in visible.lastIndex { $0.t <= t } ?? last } ?? last
        return (lo, max(lo, found))
    }

    /// The slider moved the knobs to indices lo and hi of visible.
    public mutating func setKnobs(lo: Int, hi: Int) {
        let visible = visible
        guard visible.count >= 2 else { return }
        let l = min(max(lo, 0), visible.count - 1)
        let h = min(max(hi, l), visible.count - 1)
        knobLo = l == 0 ? nil : visible[l].t
        knobHi = h == visible.count - 1 ? nil : visible[h].t
    }

    public var chopOp: EditOp? { tool { EditTrackOps.chop($0, lo: $1, hi: $2) } }
    public var cutOp: EditOp? { tool { EditTrackOps.cut($0, lo: $1, hi: $2) } }

    /// The index Split would split visible at, or nil.
    public var splitIndex: Int? {
        guard splitAt == nil else { return nil }
        let visible = visible
        let (lo, hi) = knobs(in: visible)
        return EditTrackOps.splitIndex(visible, lo: lo, hi: hi)
    }

    /// Delete point and Move point wait while a split is made.
    public var pointToolsOn: Bool { splitAt == nil }

    private func tool(_ make: ([TrackPoint], Int, Int) -> EditOp?) -> EditOp? {
        guard splitAt == nil else { return nil }
        let visible = visible
        let (lo, hi) = knobs(in: visible)
        return make(visible, lo, hi)
    }

    public mutating func chop() { push(chopOp) }
    public mutating func cut() { push(cutOp) }

    public mutating func split() {
        guard let at = splitIndex else { return }
        push(.split(t: visible[at].t))
    }

    /// Delete point on the point at t; a track keeps at least two.
    public mutating func drop(_ t: Int) {
        guard pointToolsOn, visible.count > 2 else { return }
        push(.drop(t: t))
    }

    /// Move point let go: the point at t at lon and lat.
    public mutating func move(_ t: Int, lon: Double, lat: Double) {
        guard pointToolsOn else { return }
        push(EditTrackOps.move(t: t, lon: lon, lat: lat))
    }

    public mutating func reset() { push(.reset) }

    public mutating func undo() {
        guard !ops.isEmpty else { return }
        ops.removeLast()
        toEnds()
    }

    /// Every step puts the knobs back at the ends, as the web's do.
    private mutating func push(_ op: EditOp?) {
        guard let op else { return }
        ops.append(op)
        toEnds()
    }

    private mutating func toEnds() {
        knobLo = nil
        knobHi = nil
    }
}

/// What the editor's overlay draws: lines by role (kept, preview, second), every point with
/// whether it would go, and the knobs, the web's trackEdit.ts and Android's TrackEditOverlay.
public enum TrackEditDrawing {
    public struct Point: Equatable, Sendable {
        public let point: TrackPoint
        public let removed: Bool
        /// In a split's second part.
        public var second = false
    }

    public struct Shape: Equatable, Sendable {
        public var lines: [(role: String, points: [TrackPoint])] = []
        public var points: [Point] = []
        public var knobs: [TrackPoint] = []

        public static func == (a: Shape, b: Shape) -> Bool {
            a.lines.map(\.role) == b.lines.map(\.role) && a.lines.map(\.points) == b.lines.map(\.points) && a.points == b.points && a.knobs == b.knobs
        }
    }

    /// visible with the knobs at lo and hi: the stretch between them kept and both sides dashed;
    /// with cut, that stretch dashed and a straight kept line joining the knobs; with split, the
    /// track in its two parts, the second its own color, and the one knob between them.
    public static func shape(_ visible: [TrackPoint], lo: Int, hi: Int, preview: EditPreview, split: Int?) -> Shape {
        var shape = Shape()
        let last = visible.count - 1
        guard last >= 1 else { return shape }
        func line(_ role: String, _ part: ArraySlice<TrackPoint>) {
            if part.count >= 2 { shape.lines.append((role, Array(part))) }
        }
        if let split {
            line("kept", visible[0...split])
            line("second", visible[split...last])
            shape.points = visible.enumerated().map { i, p in Point(point: p, removed: false, second: i > split) }
            shape.knobs = [visible[split]]
            return shape
        }
        let cutting = preview == .cut && hi - lo >= 2
        if cutting {
            line("kept", visible[0...lo])
            line("kept", [visible[lo], visible[hi]][...])
            line("kept", visible[hi...last])
            line("preview", visible[lo...hi])
        } else {
            line("preview", visible[0...lo])
            line("kept", visible[lo...hi])
            line("preview", visible[hi...last])
        }
        shape.points = visible.enumerated().map { i, p in
            Point(point: p, removed: cutting ? (i > lo && i < hi) : (i < lo || i > hi))
        }
        shape.knobs = lo == hi ? [visible[lo]] : [visible[lo], visible[hi]]
        return shape
    }
}

/// What Save's track write came to.
public enum TrackEditOutcome: Equatable, Sendable {
    case queued
    /// The split would leave a part entirely inside Private locations: the server's explanation,
    /// for the user to confirm with allowHidden.
    case splitHidesPart(String)
}

extension TrackEdit {
    init(_ json: TrackEditJSON) {
        self.init(
            keep: json.keep.flatMap { $0.count == 2 ? TimeSpan($0[0], $0[1]) : nil },
            remove: (json.remove ?? []).compactMap { $0.count == 2 ? TimeSpan($0[0], $0[1]) : nil },
            drop: json.drop ?? [],
            move: Dictionary((json.move ?? [:]).compactMap { k, v in Int(k).map { ($0, v) } }, uniquingKeysWith: { a, _ in a })
        )
    }

    var json: TrackEditJSON {
        TrackEditJSON(
            keep: keep.map { [$0.from, $0.to] },
            remove: remove.isEmpty ? nil : remove.map { [$0.from, $0.to] },
            drop: drop.isEmpty ? nil : drop,
            move: move.isEmpty ? nil : Dictionary(move.map { (String($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        )
    }
}

extension APIClient {
    /// `GET /v1/activities/{id}/track-points`: every point the activity was processed from,
    /// clipped by Private locations, and the edit saved on them.
    public func trackPoints(_ id: String) async throws -> (points: [TrackPoint], edit: TrackEdit?) {
        let json: TrackPointsJSON = try decode(try await send("GET", "v1/activities/\(id)/track-points"))
        let points = json.points.compactMap { p in p.count >= 3 ? TrackPoint(lon: p[0], lat: p[1], t: Int(p[2])) : nil }
        return (points, json.edit.map(TrackEdit.init))
    }

    /// `POST /v1/activities/{id}/track-edit`: the whole new edit (nil resets the track), and the
    /// split beside it; the activity reads Pending until reprocessed.
    public func saveTrackEdit(_ id: String, edit: TrackEdit?, splitAt: Int?, allowHidden: Bool) async throws -> TrackEditOutcome {
        let body = TrackEditRequestJSON(edit: edit?.json, splitAt: splitAt, allowHidden: allowHidden ? true : nil)
        do {
            _ = try await send("POST", "v1/activities/\(id)/track-edit", body: body)
            return .queued
        } catch APIError.http(422, "split_hides_part"?, let message) {
            return .splitHidesPart(message ?? "")
        }
    }
}
