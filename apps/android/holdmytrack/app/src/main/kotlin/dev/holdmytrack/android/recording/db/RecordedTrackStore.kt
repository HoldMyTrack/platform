package dev.holdmytrack.android.recording.db

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import dev.holdmytrack.android.net.Session
import dev.holdmytrack.android.recording.RecordedPoint
import java.time.Instant
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Plain `SQLiteOpenHelper`, not Room: this project's Kotlin toolchain (AGP's built-in Kotlin,
 * 2.4.0) is newer than any published KSP release at the time this was written, so Room's
 * annotation processor cannot run here — confirmed by trying it, not assumed. A hand-written
 * table is a handful of queries and no new build-tool dependency, which is what this app
 * already prefers where a platform API covers the need (`LocationManager` over Play Services'
 * `FusedLocationProviderClient`, plain `OkHttp` over Retrofit).
 */
internal class RecordingDbHelper(context: Context, name: String) :
    SQLiteOpenHelper(context.applicationContext, name, null, 7) {

    init {
        // `LiveRecordingJournal` writes on every GPS fix while other screens read the finished
        // recordings — WAL lets those reads run alongside a write and keeps each fix's commit
        // cheap.
        setWriteAheadLoggingEnabled(true)
    }

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE $TABLE (
                id TEXT PRIMARY KEY,
                account TEXT NOT NULL,
                name TEXT NOT NULL,
                description TEXT NOT NULL,
                activity_type TEXT NOT NULL,
                started_at_ms INTEGER NOT NULL,
                distance_meters REAL NOT NULL,
                duration_seconds INTEGER NOT NULL,
                points_json TEXT NOT NULL,
                created_at_ms INTEGER NOT NULL,
                sent_at_ms INTEGER
            )
            """.trimIndent(),
        )
        createJournal(db)
        createPoints(db)
    }

    /** A finished recording's points, one row each, as the journal keeps them: a single
     *  `points_json` value must fit one `CursorWindow` (2 MB), which about 18 hours of fixes
     *  outgrow, and then the row can't be read back at all. */
    private fun createPoints(db: SQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE IF NOT EXISTS $POINTS_TABLE (
                recording_id TEXT NOT NULL,
                seq INTEGER NOT NULL,
                lat REAL NOT NULL,
                lon REAL NOT NULL,
                elevation_m REAL,
                time_ms INTEGER NOT NULL,
                PRIMARY KEY (recording_id, seq)
            )
            """.trimIndent(),
        )
    }

    /**
     * Version 7's move of every row's `points_json` into [POINTS_TABLE]. Read in pieces with
     * `substr`, since a value past the `CursorWindow` limit is exactly what can't be read whole,
     * and set to `[]` once moved: the column stays, so an older build opening this file still
     * finds it. A value that doesn't parse is left as it is ([LegacyPoints]). Run again after a
     * rollback to an older build: rows already moved are skipped, and the points of rows that
     * build deleted go.
     */
    private fun movePointsOut(db: SQLiteDatabase) {
        db.execSQL("DELETE FROM $POINTS_TABLE WHERE recording_id NOT IN (SELECT id FROM $TABLE)")
        val lengths = db.rawQuery("SELECT id, length(points_json) FROM $TABLE", null).use { cursor ->
            buildList { while (cursor.moveToNext()) add(cursor.getString(0) to cursor.getLong(1)) }
        }
        for ((id, length) in lengths) {
            val json = StringBuilder()
            var from = 1L
            while (from <= length) {
                db.rawQuery("SELECT substr(points_json, ?, ?) FROM $TABLE WHERE id = ?", arrayOf(from.toString(), CHUNK.toString(), id)).use {
                    if (it.moveToFirst()) json.append(it.getString(0))
                }
                from += CHUNK
            }
            val points = LegacyPoints.parse(json.toString()) ?: continue
            writePoints(db, id, points)
            db.execSQL("UPDATE $TABLE SET points_json = ? WHERE id = ?", arrayOf(LegacyPoints.MOVED, id))
        }
    }

    /** `LiveRecordingJournal`'s two tables: the recording in progress, and its points one row
     *  each so a fix is an append rather than a rewrite of the whole track. */
    private fun createJournal(db: SQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE $LIVE_TABLE (
                id TEXT PRIMARY KEY,
                account TEXT NOT NULL,
                moving_ms INTEGER NOT NULL,
                distance_meters REAL NOT NULL
            )
            """.trimIndent(),
        )
        db.execSQL(
            """
            CREATE TABLE $LIVE_POINTS_TABLE (
                recording_id TEXT NOT NULL,
                seq INTEGER NOT NULL,
                lat REAL NOT NULL,
                lon REAL NOT NULL,
                elevation_m REAL,
                time_ms INTEGER NOT NULL,
                PRIMARY KEY (recording_id, seq)
            )
            """.trimIndent(),
        )
    }

    // Version 2 added `account` (see RecordedTrackStore's class doc for why it was
    // missing). No real users predate that, so from version 1 a plain drop-and-recreate is the
    // same "no migration tooling needed pre-launch" call the server side already makes.
    // Version 3 changed no columns: a synced row is now deleted rather than kept with a
    // `synced` status, so upgrading clears the rows that status left behind — and keeps the
    // unsynced ones, which exist nowhere else. Version 4 added the journal's tables. Version 5
    // dropped `sync_status`. Version 6 added `sent_at_ms`: a sent row stays until its ingest lands.
    // Version 7 moved the points into their own table ([createPoints]).
    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        if (oldVersion < 2) {
            db.execSQL("DROP TABLE IF EXISTS $TABLE")
            onCreate(db)
            return
        }
        if (oldVersion < 3) db.execSQL("DELETE FROM $TABLE WHERE sync_status = 'synced'")
        if (oldVersion < 4) createJournal(db)
        if (oldVersion < 5) db.execSQL("ALTER TABLE $TABLE DROP COLUMN sync_status")
        if (oldVersion < 6) db.execSQL("ALTER TABLE $TABLE ADD COLUMN sent_at_ms INTEGER")
        if (oldVersion < 7) {
            createPoints(db)
            movePointsOut(db)
        }
    }

    // An older build opening a newer database (a Play rollback, a sideloaded APK) keeps every
    // row: the default throws, and every open would crash with the only copy of each unsynced
    // recording inside. Columns are read by name, so ones a newer version added are left
    // alone, which holds only while a new version adds columns and never renames or drops one.
    // Since version 7 such a build finds every recording's points empty: they're in a table it
    // doesn't know. Upgrading again runs version 7's move a second time, which skips what moved
    // and keeps what that build recorded meanwhile (movePointsOut).
    override fun onDowngrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit

    companion object {
        @Volatile private var instance: RecordingDbHelper? = null

        /** The process's one helper for this file, so the stores and the journal share one
         *  connection pool rather than each holding its own until the collector finds it. */
        fun of(context: Context): RecordingDbHelper =
            instance ?: synchronized(this) { instance ?: RecordingDbHelper(context.applicationContext, FILE).also { instance = it } }

        /** The app's file, opened only through [of]; the instrumented tests open throwaway files. */
        const val FILE = "holdmytrack-recordings.db"
        const val TABLE = "recorded_activities"
        const val LIVE_TABLE = "live_recording"
        const val LIVE_POINTS_TABLE = "live_points"
        const val POINTS_TABLE = "recorded_points"

        /** Characters read at a time from an old `points_json`, well inside a `CursorWindow`. */
        private const val CHUNK = 500_000L

        /** Writes recording [id]'s header under [account] and its points, in the caller's
         *  transaction. */
        fun writeRecord(db: SQLiteDatabase, record: RecordedTrackRecord, account: String) {
            db.insertOrThrow(TABLE, null, record.toContentValues(account))
            writePoints(db, record.id, record.points)
        }

        private fun writePoints(db: SQLiteDatabase, id: String, points: List<RecordedPoint>) {
            db.delete(POINTS_TABLE, "recording_id = ?", arrayOf(id))
            val values = ContentValues()
            points.forEachIndexed { seq, point ->
                values.clear()
                values.put("recording_id", id)
                values.put("seq", seq)
                values.put("lat", point.lat)
                values.put("lon", point.lon)
                point.elevationM?.let { values.put("elevation_m", it) }
                values.put("time_ms", point.time.toEpochMilli())
                db.insertOrThrow(POINTS_TABLE, null, values)
            }
        }

        /** Recording [id]'s points, in order. */
        fun readPoints(db: SQLiteDatabase, id: String): List<RecordedPoint> =
            db.query(POINTS_TABLE, null, "recording_id = ?", arrayOf(id), null, null, "seq").use { cursor ->
                val lat = cursor.getColumnIndexOrThrow("lat")
                val lon = cursor.getColumnIndexOrThrow("lon")
                val elevation = cursor.getColumnIndexOrThrow("elevation_m")
                val time = cursor.getColumnIndexOrThrow("time_ms")
                buildList {
                    while (cursor.moveToNext()) {
                        add(
                            RecordedPoint(
                                lat = cursor.getDouble(lat),
                                lon = cursor.getDouble(lon),
                                elevationM = if (cursor.isNull(elevation)) null else cursor.getFloat(elevation),
                                time = Instant.ofEpochMilli(cursor.getLong(time)),
                            ),
                        )
                    }
                }
            }
    }
}

/**
 * Every local GPS recording not yet on the server — inserted by `RecordingService` on Stop,
 * listed, edited and sent from the Sync tab (`panel/SyncTab`, `sync/SyncRunner`). A sent row is
 * marked rather than deleted, and deleted once its ingest lands (`sync/SyncProgress`): until then
 * the phone holds the only copy, which a failed ingest has to be able to give back, even after
 * the app was killed. One instance per caller is fine: every one shares the process's
 * helper ([RecordingDbHelper.of]).
 *
 * **Every read and write is scoped to the currently signed-in account.** Recording works
 * whether or not anyone is signed in, and the app supports switching accounts on one device
 * (sign out, sign into a different one, or the demo) — without this, one account's recordings
 * would show up in another's Sync list. Scoped by [Session.email], the same per-account key
 * `sync/HiddenCandidates.kt` uses. A demo account shares the same empty-string key across every
 * demo session on this device, which is harmless — its data is deleted within the day either
 * way, and a demo account can never sync (the Sync tab's own demo gate), so nothing recorded
 * under it ever reaches the server regardless of which demo session sees it locally.
 */
class RecordedTrackStore internal constructor(
    private val helper: RecordingDbHelper,
    /** The signed-in account, read on every call. */
    private val account: () -> String,
) {

    constructor(context: Context) : this(RecordingDbHelper.of(context), { Session.email })

    suspend fun insert(record: RecordedTrackRecord) = withContext(Dispatchers.IO) {
        transaction { RecordingDbHelper.writeRecord(it, record, account()) }
    }

    /** The Save screen's fields, all at once, matching `handleUpdateTrack`'s own convention
     *  (`services/server/internal/httpapi/tracks.go`); the points aren't edited here. */
    suspend fun update(record: RecordedTrackRecord) = withContext(Dispatchers.IO) {
        val values = ContentValues().apply {
            put("name", record.name)
            put("description", record.description)
            put("activity_type", record.trackType)
        }
        helper.writableDatabase.update(RecordingDbHelper.TABLE, values, "id = ? AND account = ?", arrayOf(record.id, account()))
        Unit
    }

    suspend fun get(id: String): RecordedTrackRecord? = withContext(Dispatchers.IO) { row(id, withPoints = true) }

    /** [id] without its points (an empty list): what the Save screen shows and edits, which
     *  never needs a multi-hour recording's every fix. */
    suspend fun header(id: String): RecordedTrackRecord? = withContext(Dispatchers.IO) { row(id, withPoints = false) }

    private fun row(id: String, withPoints: Boolean): RecordedTrackRecord? =
        helper.readableDatabase.query(
            RecordingDbHelper.TABLE, null, "id = ? AND account = ?", arrayOf(id, account()), null, null, null,
        ).use { if (it.moveToFirst()) it.toRecord(withPoints) else null }

    /** The type of each recording waiting to be sent, for the Type picker's counts. */
    suspend fun waitingTypes(): List<String> = withContext(Dispatchers.IO) {
        helper.readableDatabase.query(
            RecordingDbHelper.TABLE, arrayOf("activity_type"), "account = ? AND sent_at_ms IS NULL", arrayOf(account()), null, null, null,
        ).use { cursor -> buildList { while (cursor.moveToNext()) add(cursor.getString(0)) } }
    }

    private fun transaction(block: (SQLiteDatabase) -> Unit) {
        val db = helper.writableDatabase
        db.beginTransaction()
        try {
            block(db)
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    /** The recordings waiting to be sent, newest first. */
    suspend fun all(): List<RecordedTrackRecord> = query("sent_at_ms IS NULL")

    /** The recordings sent whose ingest hasn't been seen to land or fail. */
    suspend fun sent(): List<RecordedTrackRecord> = query("sent_at_ms IS NOT NULL")

    private suspend fun query(where: String) = withContext(Dispatchers.IO) {
        helper.readableDatabase.query(
            RecordingDbHelper.TABLE, null, "account = ? AND $where", arrayOf(account()), null, null, "started_at_ms DESC",
        ).use { cursor -> buildList { while (cursor.moveToNext()) add(cursor.toRecord()) } }
    }

    /** The server took [id]: off the waiting list, kept until its ingest lands. */
    suspend fun markSent(id: String) = setSent(id, System.currentTimeMillis())

    /** [id]'s ingest failed: waiting to be sent again. */
    suspend fun unmarkSent(id: String) = setSent(id, null)

    private suspend fun setSent(id: String, at: Long?) = withContext(Dispatchers.IO) {
        val values = ContentValues().apply { if (at == null) putNull("sent_at_ms") else put("sent_at_ms", at) }
        helper.writableDatabase.update(RecordingDbHelper.TABLE, values, "id = ? AND account = ?", arrayOf(id, account()))
        Unit
    }

    /** Removes every recording of the signed-in account — its account was just deleted
     *  (`settings/AccountDeletion`), so nothing of it should wait here to be synced into a new one
     *  made with the same email. */
    suspend fun deleteAll() = withContext(Dispatchers.IO) {
        transaction { db ->
            db.delete(
                RecordingDbHelper.POINTS_TABLE,
                "recording_id IN (SELECT id FROM ${RecordingDbHelper.TABLE} WHERE account = ?)",
                arrayOf(account()),
            )
            db.delete(RecordingDbHelper.TABLE, "account = ?", arrayOf(account()))
        }
    }

    /** Removes a row — the user's Delete on the Sync tab, or `SyncProgress` once its ingest has
     *  landed and the track lives on the server instead. */
    suspend fun delete(id: String) = withContext(Dispatchers.IO) {
        transaction { db ->
            if (db.delete(RecordingDbHelper.TABLE, "id = ? AND account = ?", arrayOf(id, account())) > 0) {
                db.delete(RecordingDbHelper.POINTS_TABLE, "recording_id = ?", arrayOf(id))
            }
        }
    }

    private fun Cursor.toRecord(withPoints: Boolean = true) = RecordedTrackRecord(
        id = getString(getColumnIndexOrThrow("id")),
        name = getString(getColumnIndexOrThrow("name")),
        description = getString(getColumnIndexOrThrow("description")),
        trackType = getString(getColumnIndexOrThrow("activity_type")),
        startedAtMs = getLong(getColumnIndexOrThrow("started_at_ms")),
        distanceMeters = getDouble(getColumnIndexOrThrow("distance_meters")),
        durationSeconds = getLong(getColumnIndexOrThrow("duration_seconds")),
        points = if (withPoints) RecordingDbHelper.readPoints(helper.readableDatabase, getString(getColumnIndexOrThrow("id"))) else emptyList(),
        createdAtMs = getLong(getColumnIndexOrThrow("created_at_ms")),
    )
}

/** One `recorded_activities` row, under [account] — the store's signed-in account, or the
 *  journal's own when it finishes a recording made under another (`LiveRecordingJournal`). */
internal fun RecordedTrackRecord.toContentValues(account: String) = ContentValues().apply {
    put("id", id)
    put("account", account)
    put("name", name)
    put("description", description)
    put("activity_type", trackType)
    put("started_at_ms", startedAtMs)
    put("distance_meters", distanceMeters)
    put("duration_seconds", durationSeconds)
    // The points are in their own table (RecordingDbHelper.writeRecord); the column stays for
    // an older build opening this file.
    put("points_json", LegacyPoints.MOVED)
    put("created_at_ms", createdAtMs)
}
