package dev.holdmytrack.android.map

/** What a newly read list says about reprocesses: which started, which finished. */
data class PendingChange(
    /** The ids pending now. */
    val now: Set<String>,
    /** A row entered Pending. */
    val started: Boolean,
    /** A row left Pending, or an awaited edit landed. */
    val finished: Boolean,
    /** Ids that were pending and no longer are. */
    val left: Set<String>,
    /** Awaited ids that landed with this list. */
    val landed: Set<String>,
    /** Awaited ids still pending. */
    val awaiting: Set<String>,
)

/**
 * The web's `pending.ts`; both run `testdata/client-rules`. Trap: a job often finishes before
 * the reload after a save answers, so its row is never seen Pending. An edit saved here
 * (`awaiting`) therefore also counts as finished the first time a list shows it not pending.
 */
object PendingDiff {
    fun of(previous: Set<String>, now: Set<String>, awaiting: Set<String>): PendingChange {
        val left = previous - now
        val landed = awaiting - now
        return PendingChange(
            now = now,
            started = now.any { it !in previous },
            finished = left.isNotEmpty() || landed.isNotEmpty(),
            left = left,
            landed = landed,
            awaiting = awaiting intersect now,
        )
    }

    /** The ids to ask the Pending check about: the rows the list shows Pending and the edits
     *  saved here, once each, listed first. Empty means there's nothing to watch. */
    fun watched(listed: Collection<String>, awaiting: Collection<String>): List<String> = (listed + awaiting).distinct()

    /** The most ids one Pending check request may carry (`GET /v1/activities/pending`). */
    const val BATCH = 200

    /** [ids] in consecutive batches of at most [size], one Pending check request each; the
     *  answers are read as one. None for no ids. */
    fun batches(ids: List<String>, size: Int = BATCH): List<List<String>> = ids.chunked(size)

    /** Whether the Pending check's answer means the list should be read again: one of the
     *  watched ids is no longer Pending. */
    fun moved(watched: Collection<String>, stillPending: Collection<String>): Boolean = watched.any { it !in stillPending }
}
