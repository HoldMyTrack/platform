package dev.holdmytrack.android.recording

/**
 * The recording in progress, as values: its state, owner, fixes, moving time and distance.
 * `RecordingService` holds one and does the Android side (location updates, the notification,
 * the journal writes each call returns). Every call that needs the time takes [nowMs], an
 * `elapsedRealtime` reading, so moving time is immune to the wall clock changing mid-recording.
 *
 * Moving time excludes pauses, and distance has no step across one ([DistanceTally]). Fixes
 * count only while [RecordingState.RECORDING]: a paused phone's GPS drift adds nothing.
 */
class RecordingSession<F>(between: (F, F) -> Double) {

    /** What the journal's totals row records: after a pause, or when the service goes away. */
    data class Totals(val id: String, val movingMs: Long, val distanceM: Double)

    /** One fix to append to the journal, [seq] counting from 0 across the whole recording. */
    data class Appended(val id: String, val seq: Int, val point: RecordedPoint, val movingMs: Long, val distanceM: Double)

    /** A stopped recording, for Stop to save or drop ([RecordingRules.keeps]). */
    data class Finished(val id: String, val account: String, val movingMs: Long, val distanceM: Double, val points: List<RecordedPoint>)

    var state: RecordingState = RecordingState.IDLE
        private set

    /** The journal's key, and the `external_id` the saved track syncs under. */
    var id: String = ""
        private set

    /** Whoever was signed in at Start, kept even if the recording is saved under someone else. */
    var account: String = ""
        private set

    private val points = mutableListOf<RecordedPoint>()
    private val tally = DistanceTally(between)
    private var runningSinceMs = 0L
    private var movingBeforeMs = 0L

    val distanceM: Double get() = tally.meters

    /** A copy: the caller draws it while fixes keep arriving. */
    fun points(): List<RecordedPoint> = points.toList()

    fun movingMs(nowMs: Long): Long =
        if (state == RecordingState.RECORDING) movingBeforeMs + (nowMs - runningSinceMs) else movingBeforeMs

    /** A new recording [id] under [account], recording from [nowMs]. */
    fun start(id: String, account: String, nowMs: Long) {
        this.id = id
        this.account = account
        points.clear()
        tally.reset(0.0)
        movingBeforeMs = 0L
        runningSinceMs = nowMs
        state = RecordingState.RECORDING
    }

    /** Picks up a recording a process death left behind, paused, so the time the process was
     *  dead is neither moving time nor distance. False, and nothing changes, unless idle. */
    fun resume(id: String, account: String, points: List<RecordedPoint>, movingMs: Long, distanceM: Double): Boolean {
        if (state != RecordingState.IDLE) return false
        this.id = id
        this.account = account
        this.points.clear()
        this.points += points
        tally.reset(distanceM)
        movingBeforeMs = movingMs
        state = RecordingState.PAUSED
        return true
    }

    /** Pause or resume. A pause returns the totals to journal; resuming and idle return null. */
    fun toggle(nowMs: Long): Totals? = when (state) {
        RecordingState.RECORDING -> {
            movingBeforeMs += nowMs - runningSinceMs
            state = RecordingState.PAUSED
            Totals(id, movingBeforeMs, tally.meters)
        }
        RecordingState.PAUSED -> {
            runningSinceMs = nowMs
            tally.breakStep()
            state = RecordingState.RECORDING
            null
        }
        RecordingState.IDLE -> null
    }

    /** Records [fix], kept as [point], when recording; null, and nothing kept, otherwise. */
    fun add(fix: F, point: RecordedPoint, nowMs: Long): Appended? {
        if (state != RecordingState.RECORDING) return null
        tally.add(fix)
        points += point
        return Appended(id, points.size - 1, point, movingMs(nowMs), tally.meters)
    }

    /** The totals as of [nowMs] while recording, for a service going away mid-recording to
     *  journal; null otherwise, since a pause already did. */
    fun checkpoint(nowMs: Long): Totals? =
        if (state == RecordingState.RECORDING) Totals(id, movingMs(nowMs), tally.meters) else null

    /** Ends the recording and hands it over; null when there is none. */
    fun stop(nowMs: Long): Finished? {
        if (state == RecordingState.IDLE) return null
        val finished = Finished(id, account, movingMs(nowMs), tally.meters, points.toList())
        state = RecordingState.IDLE
        points.clear()
        return finished
    }

    /** Ends the recording unsaved when it belongs to [owner], whose account is gone; true when
     *  it did. Another account's recording, or none, is left alone. */
    fun discard(owner: String?): Boolean {
        if (state == RecordingState.IDLE || owner == null || account != owner) return false
        state = RecordingState.IDLE
        points.clear()
        return true
    }
}
