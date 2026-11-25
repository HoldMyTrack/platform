package dev.holdmytrack.android.sync

import androidx.health.connect.client.records.ExerciseRoute
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.metadata.Metadata
import dev.holdmytrack.android.net.ApiException
import dev.holdmytrack.android.net.HoldMyTrackApi
import dev.holdmytrack.android.net.SyncResult
import dev.holdmytrack.android.net.SyncTrackJson
import dev.holdmytrack.android.recording.RecordedPoint
import dev.holdmytrack.android.recording.db.RecordedTrackRecord
import java.io.IOException
import java.net.UnknownHostException
import java.time.Duration
import java.time.Instant
import java.time.ZoneOffset
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What a sync run sends and what it reports: which ticked tracks leave the Sync list, which are
 * refused and why, and where a failed request stops it (`docs/SPEC.md` FR-3.4, FR-3.6).
 */
class SyncRunnerTest {

    private val t0 = Instant.parse("2026-05-01T10:00:00Z")

    /** A server that answers each request from [verdict], by external id, or fails it. */
    private class Server(
        val verdict: (externalId: String) -> String = { "enqueued" },
        val failOnRequest: Int? = null,
        val failure: IOException = UnknownHostException("offline"),
    ) {
        val requests = mutableListOf<Pair<String, List<SyncTrackJson>>>()

        fun answer(tracks: List<SyncTrackJson>, source: String): List<SyncResult> {
            if (requests.size + 1 == failOnRequest) throw failure
            requests += source to tracks
            return tracks.map { track ->
                val status = verdict(track.externalId)
                SyncResult(track.externalId, status, if (status == "rejected") "refused: ${track.externalId}" else "")
            }
        }
    }

    private object Words : SyncRunner.Text {
        override fun tooManyPoints(points: Int) = "too many points: $points"
        override fun gone() = "gone"
        override fun routeUnreadable() = "route unreadable"
        override fun requestFailed() = "request failed"
        override fun noReport(status: String) = "no report: $status"
    }

    private val marked = mutableListOf<String>()

    private fun runner(server: Server, reread: (String) -> SyncCandidates.Reread? = { null }) =
        SyncRunner(
            post = { tracks, source -> server.answer(tracks, source) },
            markSent = { marked += it },
            text = Words,
            reread = { reread(it) },
        )

    private fun route(points: Int) = List(points) {
        ExerciseRoute.Location(time = t0 + Duration.ofSeconds(it * 3L), latitude = 50.0 + it / 10_000.0, longitude = 10.0)
    }

    private fun session(points: Int) = HealthConnectSession(
        ExerciseSessionRecord(
            startTime = t0, startZoneOffset = ZoneOffset.UTC,
            endTime = t0 + Duration.ofHours(1), endZoneOffset = ZoneOffset.UTC,
            metadata = Metadata.manualEntry(),
            exerciseType = ExerciseSessionRecord.EXERCISE_TYPE_WALKING,
        ),
        route(points),
    )

    /** A Health Connect session, read by this Load unless [kept] (a row from an earlier one). */
    private fun hc(id: String, points: Int = 2, kept: Boolean = false) = SyncCandidates.build(
        source = HoldMyTrackApi.SOURCE_HEALTH_CONNECT,
        externalId = id,
        startedAt = t0,
        endedAt = t0 + Duration.ofHours(1),
        trackType = "walking",
        name = "",
        lats = doubleArrayOf(50.0, 50.001),
        lons = doubleArrayOf(10.0, 10.001),
        times = longArrayOf(0L, 60_000L),
        distanceM = 130.0,
        origin = if (kept) null else session(points),
    ).copy(pointCount = points)

    private fun recording(id: String) = SyncCandidates.build(
        source = HoldMyTrackApi.SOURCE_RECORDED,
        externalId = id,
        startedAt = t0,
        endedAt = t0 + Duration.ofHours(1),
        trackType = "walking",
        name = "",
        lats = doubleArrayOf(50.0, 50.001),
        lons = doubleArrayOf(10.0, 10.001),
        times = longArrayOf(0L, 60_000L),
        distanceM = 130.0,
        origin = Recording(
            RecordedTrackRecord(
                id = id, name = "", description = "", trackType = "walking", startedAtMs = t0.toEpochMilli(),
                distanceMeters = 130.0, durationSeconds = 3_600, createdAtMs = t0.toEpochMilli(),
                points = listOf(RecordedPoint(50.0, 10.0, null, t0), RecordedPoint(50.001, 10.001, null, t0 + Duration.ofMinutes(1))),
            ),
        ),
    )

    private fun send(runner: SyncRunner, ticked: List<Candidate>, heard: MutableList<List<String>> = mutableListOf()) =
        runBlocking { runner.send(ticked, onLanded = { batch -> heard += batch.map { it.externalId } }, onProgress = {}) }

    @Test
    fun `sessions go in batches of 25 under healthconnect, and every one sent leaves the list`() {
        val server = Server()
        val ticked = List(30) { hc("s$it") }
        val heard = mutableListOf<List<String>>()

        val report = send(runner(server), ticked, heard)

        assertEquals(listOf(25, 5), server.requests.map { it.second.size })
        assertTrue(server.requests.all { it.first == HoldMyTrackApi.SOURCE_HEALTH_CONNECT })
        assertEquals(ticked.map { it.key }.toSet(), report.landed)
        assertEquals(30, report.synced)
        assertEquals(listOf(25, 5), heard.map { it.size })
        assertNull(report.stoppedBecause)
    }

    @Test
    fun `a batch is cut at 20,000 points before it reaches 25 tracks`() {
        val server = Server()
        send(runner(server), List(3) { hc("s$it", points = 8_000) })
        assertEquals(listOf(3), server.requests.map { it.second.size }) // 24,000 points: sent once full
        val second = Server()
        send(runner(second), List(4) { hc("s$it", points = 8_000) })
        assertEquals(listOf(3, 1), second.requests.map { it.second.size })
    }

    @Test
    fun `each route goes as read, every point with its time`() {
        val server = Server()
        send(runner(server), listOf(hc("s", points = 4)))
        val sent = server.requests.single().second.single()
        assertEquals("s", sent.externalId)
        assertEquals(route(4).map { it.time.toString() }, sent.points.map { it.time })
        assertTrue(sent.points.all { it.elevationM == null }) // an unknown altitude isn't sent as sea level
    }

    @Test
    fun `already there leaves the list, a refusal stays with the server's reason`() {
        val server = Server(verdict = { mapOf("a" to "enqueued", "b" to "already_processed", "c" to "rejected", "d" to "queued?")[it]!! })
        val ticked = listOf("a", "b", "c", "d").map { hc(it) }

        val report = send(runner(server), ticked)

        assertEquals(setOf(ticked[0].key, ticked[1].key), report.landed)
        assertEquals(1, report.synced)
        assertEquals(1, report.alreadyPresent)
        assertEquals(listOf("refused: c", "no report: queued?"), report.rejected.map { it.reason })
        assertEquals(listOf(ticked[2].key, ticked[3].key), report.rejected.map { it.key })
    }

    @Test
    fun `a route past the server's ceiling is refused here and never sent`() {
        val server = Server()
        val report = send(runner(server), listOf(hc("big", points = 50_001), hc("ok")))
        assertEquals(listOf("ok"), server.requests.single().second.map { it.externalId })
        assertEquals(listOf("too many points: 50001"), report.rejected.map { it.reason })
    }

    @Test
    fun `a failed request stops the run, keeping what landed before it`() {
        val server = Server(failOnRequest = 2)
        val ticked = List(30) { hc("s$it") } + recording("r")
        val heard = mutableListOf<List<String>>()

        val report = send(runner(server), ticked, heard)

        assertEquals(ticked.take(25).map { it.key }.toSet(), report.landed) // the second batch stays ticked
        assertEquals(listOf(25), heard.map { it.size })
        assertEquals("request failed", report.stoppedBecause)
        assertTrue(server.requests.none { it.first == HoldMyTrackApi.SOURCE_RECORDED })
        assertTrue(marked.isEmpty())
    }

    @Test
    fun `a kept row's route is read again, or refused with why`() {
        val server = Server()
        val reread = mapOf(
            "found" to SyncCandidates.Reread.Found(session(3)),
            "gone" to SyncCandidates.Reread.Gone,
            "refused" to SyncCandidates.Reread.Refused,
        )
        val ticked = listOf("found", "gone", "refused").map { hc(it, kept = true) }

        val report = send(runner(server) { reread[it] }, ticked)

        assertEquals(listOf("found"), server.requests.single().second.map { it.externalId })
        assertEquals(3, server.requests.single().second.single().points.size)
        assertEquals(listOf("gone", "route unreadable"), report.rejected.map { it.reason })
    }

    @Test
    fun `with Health Connect unreadable a kept row is refused, not sent without its route`() {
        val server = Server()
        val report = send(runner(server) { null }, listOf(hc("kept", kept = true)))
        assertTrue(server.requests.isEmpty())
        assertEquals(listOf("route unreadable"), report.rejected.map { it.reason })
    }

    @Test
    fun `each recording goes on its own under recorded, and only one the server took is marked sent`() {
        val server = Server(verdict = { if (it == "r2") "rejected" else "enqueued" })
        val heard = mutableListOf<List<String>>()

        val report = send(runner(server), listOf(recording("r1"), recording("r2"), recording("r3")), heard)

        assertEquals(listOf(listOf("r1"), listOf("r2"), listOf("r3")), server.requests.map { (_, tracks) -> tracks.map { it.externalId } })
        assertTrue(server.requests.all { it.first == HoldMyTrackApi.SOURCE_RECORDED })
        assertEquals(listOf("r1", "r3"), marked)
        assertEquals(listOf(listOf("r1"), listOf("r3")), heard)
        assertEquals(listOf("refused: r2"), report.rejected.map { it.reason })
    }

    @Test
    fun `a recording the server won't take is refused with its reason, and the rest go`() {
        val server = object {
            fun answer(tracks: List<SyncTrackJson>): List<SyncResult> {
                if (tracks.single().externalId == "r1") throw ApiException(413, "too big", "too_large")
                return tracks.map { SyncResult(it.externalId, "enqueued", "") }
            }
        }
        val runner = SyncRunner(post = { tracks, _ -> server.answer(tracks) }, markSent = { marked += it }, text = Words, reread = { null })

        val report = send(runner, listOf(recording("r1"), recording("r2")))

        assertEquals(listOf("r2"), marked)
        assertEquals(listOf("too big"), report.rejected.map { it.reason })
        assertNull(report.stoppedBecause)
    }

    @Test
    fun `a failed recording stops the run with the ones before it marked sent`() {
        val server = Server(failOnRequest = 2)
        val report = send(runner(server), listOf(recording("r1"), recording("r2"), recording("r3")))
        assertEquals(listOf("r1"), marked)
        assertEquals("request failed", report.stoppedBecause)
        assertEquals(1, server.requests.size)
    }
}
