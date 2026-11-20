import Foundation
import SQLite3

/// The recording in progress, written as it happens (apps/ios/docs/IMPLEMENTATION.md §5), so a
/// crash or a swipe in the app switcher leaves it on disk rather than taking it with the app's
/// memory: one row for the recording and its totals, one row per fix, each write committed as
/// it's made. Android's LiveRecordingJournal.
///
/// At most one recording is ever in the journal, and only while one is in progress: Stop saves
/// it to the store under its own id and then clears the journal, so a journal row with nothing
/// recording in this run is a leftover, and saving one twice writes the same file.
public final class RecordingJournal: @unchecked Sendable {
    private var db: OpaquePointer?

    /// What a recording that died left: its account, start, moving time and distance as of its
    /// last fix or pause, and every fix. Moving time is a duration, so the time the app was dead
    /// counts as a pause.
    public struct Leftover: Equatable, Sendable {
        public let id: String
        public let account: String
        public let startedAt: Date
        public let moving: TimeInterval
        public let meters: Double
        public let points: [RecordedPoint]
    }

    public init(path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(path.path, &db) == SQLITE_OK else { throw JournalError.open }
        try run("""
            CREATE TABLE IF NOT EXISTS live_recording (
                id TEXT PRIMARY KEY, account TEXT NOT NULL, started_at REAL NOT NULL,
                moving REAL NOT NULL, meters REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS live_points (
                seq INTEGER PRIMARY KEY AUTOINCREMENT, recording_id TEXT NOT NULL,
                lat REAL NOT NULL, lon REAL NOT NULL, ele REAL, time REAL NOT NULL);
            """)
    }

    deinit { sqlite3_close(db) }

    public enum JournalError: Error { case open, write(String) }

    /// A new recording, in place of anything left.
    public func begin(id: String, account: String, startedAt: Date) throws {
        try transaction {
            try run("DELETE FROM live_points; DELETE FROM live_recording;")
            try write("INSERT INTO live_recording (id, account, started_at, moving, meters) VALUES (?, ?, ?, 0, 0)",
                      [.text(id), .text(account), .real(startedAt.timeIntervalSince1970)])
        }
    }

    /// One fix, with the totals it brings the recording to, in one commit.
    public func append(_ point: RecordedPoint, id: String, moving: TimeInterval, meters: Double) throws {
        try transaction {
            try write("INSERT INTO live_points (recording_id, lat, lon, ele, time) VALUES (?, ?, ?, ?, ?)",
                      [.text(id), .real(point.lat), .real(point.lon), point.ele.map(Value.real) ?? .null, .real(point.time.timeIntervalSince1970)])
            try totals(id: id, moving: moving, meters: meters)
        }
    }

    /// The totals as of a pause, or as the app goes away.
    public func totals(id: String, moving: TimeInterval, meters: Double) throws {
        try write("UPDATE live_recording SET moving = ?, meters = ? WHERE id = ?", [.real(moving), .real(meters), .text(id)])
    }

    /// The recording stopped and saved, or discarded: the journal is empty again.
    public func clear() throws {
        try run("DELETE FROM live_points; DELETE FROM live_recording;")
    }

    /// What's left, if anything.
    public func leftover() -> Leftover? {
        var row: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, account, started_at, moving, meters FROM live_recording LIMIT 1", -1, &row, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(row) }
        guard sqlite3_step(row) == SQLITE_ROW else { return nil }
        let id = String(cString: sqlite3_column_text(row, 0))
        let account = String(cString: sqlite3_column_text(row, 1))
        let startedAt = Date(timeIntervalSince1970: sqlite3_column_double(row, 2))
        let moving = sqlite3_column_double(row, 3), meters = sqlite3_column_double(row, 4)
        var points: [RecordedPoint] = []
        var fix: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT lat, lon, ele, time FROM live_points WHERE recording_id = ? ORDER BY seq", -1, &fix, nil) == SQLITE_OK {
            sqlite3_bind_text(fix, 1, id, -1, Self.transient)
            while sqlite3_step(fix) == SQLITE_ROW {
                let ele: Double? = sqlite3_column_type(fix, 2) == SQLITE_NULL ? nil : sqlite3_column_double(fix, 2)
                points.append(RecordedPoint(lat: sqlite3_column_double(fix, 0), lon: sqlite3_column_double(fix, 1), ele: ele,
                                            time: Date(timeIntervalSince1970: sqlite3_column_double(fix, 3))))
            }
            sqlite3_finalize(fix)
        }
        return Leftover(id: id, account: account, startedAt: startedAt, moving: moving, meters: meters, points: points)
    }

    // MARK: SQLite

    private enum Value { case text(String), real(Double), null }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func run(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw JournalError.write(String(cString: sqlite3_errmsg(db))) }
    }

    private func write(_ sql: String, _ values: [Value]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw JournalError.write(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let at = Int32(index + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, at, text, -1, Self.transient)
            case .real(let number): sqlite3_bind_double(statement, at, number)
            case .null: sqlite3_bind_null(statement, at)
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw JournalError.write(String(cString: sqlite3_errmsg(db))) }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try run("BEGIN")
        do {
            try body()
            try run("COMMIT")
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }
}

/// What the app does about a leftover when the signed-in screen opens (apps/android/docs/SPEC.md
/// FR-5.1): nothing while a recording runs; a leftover from another account waits for it; the
/// notification posted as the app was swiped away resumes it with no prompt; otherwise the map
/// asks to Resume, Save or Discard. Nothing restarts on its own.
public enum LeftoverAction: Equatable, Sendable {
    case none, wait, resume, prompt

    public static func of(leftover account: String?, signedIn: String, recording: RecordingState, resumeAsked: Bool) -> LeftoverAction {
        guard let account, recording == .idle else { return .none }
        guard account == signedIn else { return .wait }
        return resumeAsked ? .resume : .prompt
    }
}