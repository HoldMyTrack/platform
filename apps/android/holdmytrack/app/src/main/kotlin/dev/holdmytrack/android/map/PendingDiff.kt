package dev.holdmytrack.android.map

/** What a newly read list says about reprocesses: which started, which finished. */
data class PendingChange(
    /** The ids held Pending: the list's, and those it doesn't show that were. */
    val pending: Set<String>,
    /** A row entered Pending. */
    val started: Boolean,
    /** A row left Pending, or an awaited edit landed. */
    val finished: Boolean,
    /** Ids that were pending and no longer are. */
    val left: Set<String>,
    /** Awaited ids that landed with this list. */
    val landed: Set<String>,
    /** Awaited ids not seen landing. */
    val awaiting: Set<String>,
)

/** What the Pending check's answer says: [moved] means reading the list again, [finished] are the
 *  watched ids the list doesn't show that are no longer Pending. */
data class PendingAnswer(val moved: Boolean, val finished: Set<String>)

/**
 * The web's `pending.ts`; both run `testdata/client-rules`. Trap: a job often finishes before
 * the reload after a save answers, so its row is never seen Pending. An edit saved here
 * (`awaiting`) therefore also counts as finished the first time a list shows it not pending.
 *
 * Trap: the list is an area's, and a move of the map takes rows out of it. A missing row says
 * nothing about its reprocess, so a list speaks only for the rows it holds (`listed`), and the
 * Pending check answers for the rest ([answer]).
 */
object PendingDiff {
    fun of(previous: Set<String>, now: Set<String>, awaiting: Set<String>, listed: Set<String>): PendingChange {
        val done = { id: String -> id in listed && id !in now }
        val left = previous.filterTo(HashSet(), done)
        val landed = awaiting.filterTo(HashSet(), done)
        return PendingChange(
            pending = now + previous.filter { it !in listed },
            started = now.any { it !in previous },
            finished = left.isNotEmpty() || landed.isNotEmpty(),
            left = left,
            landed = landed,
            awaiting = awaiting - landed,
        )
    }

    /** The ids to ask the Pending check about: the rows held Pending and the edits saved here,
     *  once each, Pending first. Empty means there's nothing to watch. */
    fun watched(pending: Collection<String>, awaiting: Collection<String>): List<String> = (pending + awaiting).distinct()

    /** The most ids one Pending check request may carry (`GET /v1/activities/pending`). */
    const val BATCH = 200

    /** [ids] in consecutive batches of at most [size], one Pending check request each; the
     *  answers are read as one. None for no ids. */
    fun batches(ids: List<String>, size: Int = BATCH): List<List<String>> = ids.chunked(size)

    /** What the Pending check's answer says about the [watched] ids no longer Pending: one the
     *  list holds means reading it again; one it doesn't has finished, since no list will say so. */
    fun answer(watched: Collection<String>, stillPending: Collection<String>, listed: Set<String>): PendingAnswer {
        val still = stillPending.toSet()
        val done = watched.filter { it !in still }
        return PendingAnswer(moved = done.any { it in listed }, finished = done.filterTo(HashSet()) { it !in listed })
    }
}
