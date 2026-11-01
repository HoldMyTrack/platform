package dev.holdmytrack.android.sync

/**
 * Groups the sessions a sync sends into requests: a request goes once it holds [maxActivities]
 * activities or [maxPoints] points, whichever comes first, and what's left goes at the end.
 */
class SyncBatcher<T>(
    private val maxActivities: Int = MAX_BATCH_ACTIVITIES,
    private val maxPoints: Int = MAX_BATCH_POINTS,
) {
    private val batch = mutableListOf<T>()
    private var points = 0

    /** Adds [item], of [pointCount] points: the batch to send now when this filled it, else null. */
    fun add(item: T, pointCount: Int): List<T>? {
        batch += item
        points += pointCount
        return if (batch.size >= maxActivities || points >= maxPoints) take() else null
    }

    /** What's left to send once the last item is in; empty when nothing is. */
    fun rest(): List<T> = take()

    private fun take(): List<T> = batch.toList().also {
        batch.clear()
        points = 0
    }

    companion object {
        /** The endpoint accepts 100 per request; a smaller batch keeps one request modest on
         *  mobile data. */
        const val MAX_BATCH_ACTIVITIES = 25
        const val MAX_BATCH_POINTS = 20_000

        /** The server's ceiling, checked here so a route it could never accept is reported as
         *  such instead of being sent to be refused. */
        const val MAX_POINTS_PER_ACTIVITY = 50_000

        /** Whether a route of [pointCount] points is past what the server accepts. */
        fun tooLarge(pointCount: Int): Boolean = pointCount > MAX_POINTS_PER_ACTIVITY
    }
}