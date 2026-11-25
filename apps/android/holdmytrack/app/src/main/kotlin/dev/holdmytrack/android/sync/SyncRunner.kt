package dev.holdmytrack.android.sync

import android.content.res.Resources
import android.util.Log
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.records.ExerciseRoute
import dev.holdmytrack.android.R
import dev.holdmytrack.android.net.FailureText
import dev.holdmytrack.android.net.HoldMyTrackApi
import dev.holdmytrack.android.net.SyncResult
import dev.holdmytrack.android.net.SyncTrackJson
import dev.holdmytrack.android.net.SyncPointJson
import dev.holdmytrack.android.recording.db.RecordedTrackStore
import dev.holdmytrack.android.recording.db.toSyncTrack
import java.io.IOException
import java.time.Instant
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** One ticked track the server refused, or that it could never accept, with the reason why. */
data class Rejection(val key: String, val startedAt: Instant, val trackType: String, val reason: String)

/** What a finished (or curtailed) run did. */
data class SyncReport(
    /** The keys the account has now — sent, or already there: off the list. */
    val landed: Set<String>,
    val synced: Int,
    val alreadyPresent: Int,
    val rejected: List<Rejection>,
    /** Null when everything ticked was sent; otherwise why the run stopped short. */
    val stoppedBecause: String?,
)

/**
 * Sends what the user ticked on the Sync tab (`docs/SPEC.md` FR-3.4, FR-3.6) to
 * `POST /v2/sync/tracks`, and nothing else: an unticked candidate never reaches the server.
 * Health Connect sessions go in batches under `healthconnect`; each recording in a request of its
 * own under `recorded`, kept on the phone until its ingest lands ([SyncProgress]).
 *
 * Interrupting a run is safe: the server is idempotent on `(user_id, source, external_id)`, so
 * whatever was sent before the cut is simply known next time the list is read (`POST
 * /v2/sync/known`), and sending one again answers `already_processed`.
 *
 * **Foreground only** (`docs/IMPLEMENTATION.md` §4.0): routes written by other apps read back as
 * `ConsentRequired` in the background, so the routes sent here are the ones the Sync tab read
 * while it was on screen — or, for a row kept from an earlier Load ([WaitingStore]),
 * read again here, by its id, as the run reaches it ([SyncCandidates.reread]) — and the tab
 * cancels a run when it leaves.
 */
class SyncRunner internal constructor(
    /** `POST /v2/sync/tracks`: the server's verdicts, or an [IOException] for a request that failed. */
    private val post: suspend (tracks: List<SyncTrackJson>, source: String) -> List<SyncResult>,
    /** Marks the recording with this external id sent ([RecordedTrackStore.markSent]). */
    private val markSent: suspend (externalId: String) -> Unit,
    private val text: Text,
    /** Reads a kept row's route again by its external id; null when Health Connect can't be read. */
    private val reread: suspend (externalId: String) -> SyncCandidates.Reread?,
) {
    constructor(
        store: RecordedTrackStore,
        res: Resources,
        healthConnect: HealthConnectClient?,
    ) : this(
        post = { tracks, source ->
            try {
                HoldMyTrackApi.syncTracks(tracks, source)
            } catch (e: IOException) {
                Log.w(TAG, "sync batch failed", e)
                throw e
            }
        },
        markSent = store::markSent,
        text = ResourceText(res),
        reread = { id -> healthConnect?.let { SyncCandidates.reread(it, id) } },
    )

    /** The reasons a run reports, the refusals and why it stopped, in the app's language. */
    internal interface Text {
        fun tooManyPoints(points: Int): String
        fun gone(): String
        fun routeUnreadable(): String
        fun requestFailed(): String
        fun noReport(status: String): String
    }

    private class ResourceText(private val res: Resources) : Text {
        override fun tooManyPoints(points: Int) = res.getQuantityString(R.plurals.sync_refusal_too_many_points, points, points)
        override fun gone() = res.getString(R.string.sync_refusal_gone)
        override fun routeUnreadable() = res.getString(R.string.sync_refusal_route)
        override fun requestFailed() = res.getString(R.string.sync_request_failed)
        override fun noReport(status: String) = res.getString(R.string.sync_no_report, status)
    }

    private val landed = mutableSetOf<String>()
    private var synced = 0
    private var alreadyPresent = 0
    private val rejected = mutableListOf<Rejection>()
    private var onLanded: (List<Candidate>) -> Unit = {}
    private var onRejected: (Rejection) -> Unit = {}
    private var skip: (Candidate) -> Boolean = { false }
    private var onAsked: (Candidate, Boolean) -> Unit = { _, _ -> }

    /**
     * Sends [ticked]. [onLanded] hears each batch the account has now as it lands — a recording
     * once marked sent — so a run cancelled or failing part-way (the tab leaving, a bad answer)
     * keeps what landed before it; [onRejected] likewise hears each refusal,
     * and [onAsked] whether each recording's request failed with nothing decided. A recording [skip] names as
     * its turn comes isn't sent.
     */
    suspend fun send(
        ticked: List<Candidate>,
        onLanded: (List<Candidate>) -> Unit,
        onRejected: (Rejection) -> Unit = {},
        skip: (Candidate) -> Boolean = { false },
        onAsked: (Candidate, Boolean) -> Unit = { _, _ -> },
        onProgress: (sent: Int) -> Unit,
    ): SyncReport {
        this.onLanded = onLanded
        this.onRejected = onRejected
        this.skip = skip
        this.onAsked = onAsked
        val stopped = sendSessions(ticked.filter { it.source == HoldMyTrackApi.SOURCE_HEALTH_CONNECT }, onProgress)
            ?: sendRecordings(ticked.filter { it.origin is Recording }, onProgress)
        return SyncReport(landed.toSet(), synced, alreadyPresent, rejected.toList(), stopped)
    }

    /** Health Connect's ticked sessions, a batch at a time. Returns why it stopped, if it did. */
    private suspend fun sendSessions(sessions: List<Candidate>, onProgress: (Int) -> Unit): String? {
        val batches = SyncBatcher<Candidate>()
        for (ticked in sessions) {
            val candidate = withRoute(ticked) ?: continue
            if (SyncBatcher.tooLarge(candidate.pointCount)) {
                reject(candidate, text.tooManyPoints(candidate.pointCount))
                continue
            }
            val full = batches.add(candidate, candidate.pointCount) ?: continue
            flush(full, HoldMyTrackApi.SOURCE_HEALTH_CONNECT)?.let { return it }
            onProgress(landed.size)
        }
        val stopped = flush(batches.rest(), HoldMyTrackApi.SOURCE_HEALTH_CONNECT)
        onProgress(landed.size)
        return stopped
    }

    /** [candidate] with its route: as read by this Load, or read again now for a row
     *  kept from an earlier one. Null, with the reason among the refusals, when it can't be. */
    private suspend fun withRoute(candidate: Candidate): Candidate? {
        if (candidate.origin != null) return candidate
        val reason = when (val again = reread(candidate.externalId)) {
            is SyncCandidates.Reread.Found -> return candidate.copy(origin = again.origin, pointCount = again.origin.route.size)
            SyncCandidates.Reread.Gone -> text.gone()
            SyncCandidates.Reread.Refused, null -> text.routeUnreadable()
        }
        reject(candidate, reason)
        return null
    }

    /** Each ticked recording on its own; one the server takes is marked sent, and stays on the
     *  phone until its ingest lands (`SyncProgress`). One whose request failed doesn't hold up the
     *  rest unless they'd fail too ([RecordingSendRules.failure]). */
    private suspend fun sendRecordings(recordings: List<Candidate>, onProgress: (Int) -> Unit): String? {
        var afterUnanswered = false
        for (candidate in recordings) {
            if (skip(candidate)) continue
            val batch = listOf(candidate)
            try {
                sort(batch, post(batch.map { prepare(it) }, HoldMyTrackApi.SOURCE_RECORDED))
                afterUnanswered = false
                onAsked(candidate, false)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                val reason = FailureText.of(e, text.requestFailed())
                val failure = RecordingSendRules.failure(e, afterUnanswered)
                afterUnanswered = RecordingSendRules.unanswered(e)
                onAsked(candidate, failure != RecordingSendRules.Failure.REFUSE)
                when (failure) {
                    RecordingSendRules.Failure.STOP -> return reason
                    RecordingSendRules.Failure.NEXT -> Unit
                    RecordingSendRules.Failure.REFUSE -> reject(candidate, reason)
                }
            }
            if (candidate.key in landed) {
                markSent(candidate.externalId)
                onLanded(listOf(candidate))
            }
            onProgress(landed.size)
        }
        return null
    }

    /**
     * Sends a [batch] of sessions and sorts the server's verdicts, telling [onLanded] what
     * landed. Returns null when the run may go on, or the
     * reason to stop: a failed request decided nothing, so the batch stays ticked on the list.
     */
    private suspend fun flush(batch: List<Candidate>, source: String): String? {
        if (batch.isEmpty()) return null
        val results = try {
            post(batch.map { prepare(it) }, source)
        } catch (e: IOException) {
            return FailureText.of(e, text.requestFailed())
        }
        val now = sort(batch, results)
        if (now.isNotEmpty()) onLanded(now)
        return null
    }

    private fun reject(candidate: Candidate, reason: String) {
        val rejection = Rejection(candidate.key, candidate.startedAt, candidate.trackType, reason)
        rejected += rejection
        onRejected(rejection)
    }

    /** Counts the server's verdicts on [batch] ([SyncVerdicts]); what the account has now. */
    private fun sort(batch: List<Candidate>, results: List<SyncResult>): List<Candidate> {
        val verdicts = SyncVerdicts.of(batch, results)
        synced += verdicts.enqueued.size
        alreadyPresent += verdicts.alreadyPresent.size
        val now = verdicts.enqueued + verdicts.alreadyPresent
        landed += now.map { it.key }
        for ((candidate, result) in verdicts.refused) {
            val reason = result?.error?.ifBlank { null } ?: text.noReport(result?.status ?: "missing")
            reject(candidate, reason)
        }
        return now
    }

    /**
     * The wire shape `POST /v2/sync/tracks` accepts (`docs/IMPLEMENTATION.md` §4.0.3), built
     * from the route as read — never the simplified line the map draws.
     *
     * `external_id` is Health Connect's own record id, or the recording's UUID: the endpoint keys
     * idempotency on `(user_id, source, external_id)`, which is what makes a re-sent track the
     * same track rather than a new one.
     *
     * Elevation is sent when the location carries it and omitted otherwise, rather than defaulted
     * to zero — an unknown altitude is not sea level. Heart rate is never read or sent: HoldMyTrack
     * keeps no health data, only the geography (`docs/VISION.md` §1.1).
     *
     * Built off the main thread: a long ride is tens of thousands of points.
     */
    private suspend fun prepare(candidate: Candidate): SyncTrackJson = withContext(Dispatchers.Default) {
        when (val origin = candidate.origin) {
            is Recording -> origin.record.toSyncTrack()
            is HealthConnectSession -> SyncTrackJson(
                externalId = candidate.externalId,
                trackType = candidate.trackType,
                points = origin.route.map {
                    SyncPointJson(lat = it.latitude, lon = it.longitude, elevationM = it.altitude?.inMeters, time = it.time.toString())
                },
            )
            null -> error("candidate ${candidate.key} has nothing to send")
        }
    }

    private companion object {
        const val TAG = "HoldMyTrackSync"
    }
}
