package dev.holdmytrack.android.map

import android.view.View
import dev.holdmytrack.android.net.Activity
import dev.holdmytrack.android.net.HoldMyTrackApi

/**
 * Pending rows (a reprocess running, from here or another client): each list read says which
 * started or finished ([PendingDiff]). While any is Pending, or an edit saved here is awaited, the
 * small Pending check runs every [POLL_MS] and the list is read again once it says one finished.
 * A failed check or read keeps polling: a Pending row still has to be seen finishing.
 */
class PendingTracker(
    /** The view whose handler runs the poll. */
    private val host: () -> View?,
    private val reload: () -> Unit,
) {
    /** The ids the last list showed Pending. */
    private var pendingIds: Set<String> = emptySet()

    /**
     * Activities whose track edit was saved here and whose reprocess hasn't been seen finishing.
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
        val still = HashSet<String>()
        var outstanding = batches.size
        var failed = false
        for (batch in batches) {
            HoldMyTrackApi.pendingActivities(batch) { result ->
                result.onSuccess { still += it }.onFailure { failed = true }
                if (--outstanding > 0) return@pendingActivities
                if (!failed && PendingDiff.moved(watched, still)) reload() else schedule()
            }
        }
    }

    fun awaitEdit(id: String) {
        awaiting += id
    }

    /** A list was read: what it says about reprocesses, with the poll scheduled while any runs. */
    fun track(activities: List<Activity>): PendingChange {
        val change = PendingDiff.of(pendingIds, activities.filter { it.pending }.mapTo(HashSet()) { it.id }, awaiting)
        awaiting.retainAll(change.awaiting)
        pendingIds = change.now
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
