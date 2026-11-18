package dev.holdmytrack.android.map

import android.view.View
import dev.holdmytrack.android.net.Track
import dev.holdmytrack.android.net.HoldMyTrackApi

/**
 * Pending rows (a reprocess running, from here or another client): each list read says which
 * started or finished ([PendingDiff]). While any is held Pending, or an edit saved here is awaited,
 * the small Pending check runs every [POLL_MS]: the list is read again once it says a listed one
 * finished, and [finished] hears of those the list doesn't show. A failed check or read keeps
 * polling: a Pending row still has to be seen finishing.
 *
 * Trap: [awaitEdit] and [track] restart the poll and drop the answer of a check in flight: asked
 * before the save, it would count the new edit as landed, and asked before the list, it would be
 * read against the rows the list held then.
 */
class PendingTracker(
    /** The view whose handler runs the poll. */
    private val host: () -> View?,
    private val reload: () -> Unit,
    /** Ids the list doesn't show finished, by the Pending check alone. */
    private val finished: (Set<String>) -> Unit,
) {
    /** The ids held Pending ([PendingChange.pending]). */
    private var pendingIds: Set<String> = emptySet()

    /** The ids the last list held. */
    private var listedIds: Set<String> = emptySet()

    /** Bumped by [awaitEdit] and [track]: an answer to a check sent before is dropped. */
    private var generation = 0

    /**
     * Tracks whose route edit was saved here and whose reprocess hasn't been seen finishing.
     * Trap: the job often finishes before the reload after the save answers, so the row is never
     * seen Pending at all.
     */
    private val awaiting = HashSet<String>()

    private val poll = Runnable { check() }

    private fun check() {
        val watched = PendingDiff.watched(pendingIds, awaiting)
        if (watched.isEmpty()) return
        // One request per batch the endpoint accepts; answers arrive on the main thread, and the
        // last one decides from all of them. A failed batch means polling on.
        val batches = PendingDiff.batches(watched)
        val sent = generation
        val listed = listedIds
        val still = HashSet<String>()
        var outstanding = batches.size
        var failed = false
        for (batch in batches) {
            HoldMyTrackApi.pendingTracks(batch) { result ->
                result.onSuccess { still += it }.onFailure { failed = true }
                if (--outstanding > 0 || sent != generation) return@pendingTracks
                if (failed) return@pendingTracks schedule()
                val answer = PendingDiff.answer(watched, still, listed)
                if (answer.finished.isNotEmpty()) {
                    pendingIds = pendingIds - answer.finished
                    awaiting.removeAll(answer.finished)
                    finished(answer.finished)
                }
                if (answer.moved) reload() else schedule()
            }
        }
    }

    fun awaitEdit(id: String) {
        awaiting += id
        generation++
        schedule()
    }

    /** A list was read: what it says about reprocesses, with the poll scheduled while any runs. */
    fun track(tracks: List<Track>): PendingChange {
        generation++
        listedIds = tracks.mapTo(HashSet()) { it.id }
        val change = PendingDiff.of(pendingIds, tracks.filter { it.pending }.mapTo(HashSet()) { it.id }, awaiting, listedIds)
        awaiting.retainAll(change.awaiting)
        pendingIds = change.pending
        schedule()
        return change
    }

    /** A read failed: polling goes on while rows were Pending. */
    fun readFailed() = schedule()

    fun stop() {
        host()?.removeCallbacks(poll)
    }

    private fun schedule() {
        val view = host() ?: return
        view.removeCallbacks(poll)
        if (pendingIds.isNotEmpty() || awaiting.isNotEmpty()) view.postDelayed(poll, POLL_MS)
    }

    private companion object {
        const val POLL_MS = 2_000L
    }
}
