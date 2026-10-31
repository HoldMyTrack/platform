package dev.holdmytrack.android.sync

import dev.holdmytrack.android.net.SyncResult

/** A sync batch sorted by the server's answer to each of its activities, in the batch's order. */
data class SyncVerdicts(
    /** Queued for ingest. */
    val enqueued: List<Candidate>,
    /** The account had it already. */
    val alreadyPresent: List<Candidate>,
    /** Refused, or missing from the answer (null): it stays ticked on the list. */
    val refused: List<Pair<Candidate, SyncResult?>>,
) {
    companion object {
        fun of(batch: List<Candidate>, results: List<SyncResult>): SyncVerdicts {
            val byId = results.associateBy { it.externalId }
            val enqueued = mutableListOf<Candidate>()
            val present = mutableListOf<Candidate>()
            val refused = mutableListOf<Pair<Candidate, SyncResult?>>()
            for (candidate in batch) {
                val result = byId[candidate.externalId]
                when (result?.status) {
                    "enqueued" -> enqueued += candidate
                    "already_processed" -> present += candidate
                    else -> refused += candidate to result
                }
            }
            return SyncVerdicts(enqueued, present, refused)
        }
    }
}