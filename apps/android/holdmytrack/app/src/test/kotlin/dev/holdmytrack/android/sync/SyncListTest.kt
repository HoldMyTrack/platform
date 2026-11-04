package dev.holdmytrack.android.sync

import java.time.Duration
import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Test

/** What the Sync tab lists and offers (`apps/android/docs/SPEC.md` FR-3.2, FR-3.4). */
class SyncListTest {

    private val t0 = Instant.parse("2026-05-01T08:00:00Z")

    private fun candidate(source: String, id: String, hoursAgo: Long, type: String = "walking") = SyncCandidates.build(
        source = source,
        externalId = id,
        startedAt = t0 - Duration.ofHours(hoursAgo),
        endedAt = t0 - Duration.ofHours(hoursAgo) + Duration.ofMinutes(30),
        activityType = type,
        name = "",
        lats = doubleArrayOf(50.0, 50.001),
        lons = doubleArrayOf(10.0, 10.001),
        times = longArrayOf(0L, 60_000L),
        distanceM = 130.0,
        origin = null,
    )

    private val session = candidate("healthconnect", "s1", 1)
    private val knownSession = candidate("healthconnect", "s2", 2)
    private val ride = candidate("healthconnect", "s3", 3, type = "cycling")
    private val recording = candidate("recorded", "r1", 4)
    private val sending = candidate("recorded", "r2", 5)

    private fun keys(list: List<Candidate>) = list.map { it.externalId }

    private fun list(
        hidden: Set<String> = emptySet(),
        showHidden: Boolean = false,
        types: Set<String> = emptySet(),
        ticked: Set<String> = emptySet(),
    ) = SyncList.of(
        sessions = listOf(session, knownSession, ride),
        known = setOf("s2"),
        recordings = listOf(recording),
        hidden = hidden,
        showHidden = showHidden,
        types = types,
        inFlight = listOf(sending),
        ticked = ticked,
    )

    @Test
    fun `a session the server has is left out, and what's on its way is listed, newest first`() {
        val l = list()
        assertEquals(listOf("s1", "s3", "r1", "r2"), keys(l.everything))
        assertEquals(listOf("s1", "s3", "r1", "r2"), keys(l.shown))
    }

    @Test
    fun `what's on its way is listed but not drawn, ticked or sent`() {
        val l = list(ticked = setOf(sending.key, session.key))
        assertEquals(listOf("s1", "s3", "r1"), keys(l.drawn))
        assertEquals(listOf("s1", "s3", "r1"), keys(l.tickable))
        assertEquals(listOf("s1"), keys(l.sendable))
    }

    @Test
    fun `a hidden row shows only with Show hidden, and is never offered`() {
        val hidden = setOf(ride.key)
        assertEquals(listOf("s1", "r1", "r2"), keys(list(hidden = hidden).shown))
        val shownHidden = list(hidden = hidden, showHidden = true, ticked = setOf(ride.key))
        assertEquals(listOf("s1", "s3", "r1", "r2"), keys(shownHidden.shown))
        assertEquals(emptyList<String>(), keys(shownHidden.sendable))
        assertEquals(listOf("s1", "r1"), keys(shownHidden.offered))
    }

    @Test
    fun `the type filter narrows what's shown and sent, not everything`() {
        val l = list(types = setOf("cycling"), ticked = setOf(session.key, ride.key))
        assertEquals(listOf("s3"), keys(l.shown))
        assertEquals(listOf("s3"), keys(l.sendable))
        assertEquals(4, l.everything.size)
    }
}