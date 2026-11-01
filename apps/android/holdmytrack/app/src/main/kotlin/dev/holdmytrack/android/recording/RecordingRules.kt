package dev.holdmytrack.android.recording

/** What a recording keeps, as values: whether Stop saves it, and the distance it covered. */
object RecordingRules {
    /** A recording shorter than this, moving time with pauses excluded, is dropped on Stop
     *  rather than saved: an accidental tap, not an activity anyone meant to keep. */
    const val MIN_DURATION_MS = 60_000L

    /** Whether Stop saves a recording of [movingMs] moving time and [points] fixes: at least a
     *  minute, and two points to draw a line between. */
    fun keeps(movingMs: Long, points: Int): Boolean = movingMs >= MIN_DURATION_MS && points >= 2
}

/**
 * A recording's distance: each fix's step from the one before, measured by [between], and none
 * across a pause. The first fix after a pause is a fresh baseline, not a jump from wherever the
 * phone was when it paused, which would count the gap as distance.
 */
class DistanceTally<P>(private val between: (P, P) -> Double) {
    var meters = 0.0
        private set
    private var last: P? = null

    /** Adds [fix]'s step from the fix before it, if there is one since the last break. */
    fun add(fix: P) {
        last?.let { meters += between(it, fix) }
        last = fix
    }

    /** A pause: the next fix starts afresh. */
    fun breakStep() {
        last = null
    }

    /** Starts over at [meters] (a new recording, or a leftover picked up where it was). */
    fun reset(meters: Double) {
        this.meters = meters
        last = null
    }
}