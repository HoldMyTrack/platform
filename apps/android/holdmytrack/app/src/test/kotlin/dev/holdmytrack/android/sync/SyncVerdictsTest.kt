package dev.holdmytrack.android.sync

import dev.holdmytrack.android.net.SyncResult
import java.time.Duration
import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Test

/** How a sync batch is sorted by the server's answer (`docs/SPEC.md` FR-3.6). */
class SyncVerdictsTest {

    private val t0 = Instant.parse("2026-05-01T10:00:00Z")

    private fun candidate(id: String) = SyncCandidates.build(
        source = "healthconnect",
        externalId = id,
        startedAt = t0,
        endedAt = t0 + Duration.ofMinutes(30),
        activityType = "walking",
        name = "",
        lats = doubleArrayOf(50.0, 50.001),
        lons = doubleArrayOf(10.0, 10.001),
        times = longArrayOf(0L, 60_000L),
        distanceM = 130.0,
        origin = null,
    )

    @Test
    fun `each activity is sorted by its own answer, in the batch's order`() {
        val (a, b, c, d) = listOf("a", "b", "c", "d").map(::candidate)
        val refusal = SyncResult("c", "rejected", "too many points")
        val verdicts = SyncVerdicts.of(
            listOf(a, b, c, d),
            listOf(SyncResult("b", "already_processed", ""), refusal, SyncResult("a", "enqueued", "")),
        )
        assertEquals(listOf(a), verdicts.enqueued)
        assertEquals(listOf(b), verdicts.alreadyPresent)
        assertEquals(listOf(c to refusal, d to null), verdicts.refused)
    }

    @Test
    fun `an empty batch has no verdicts`() {
        assertEquals(SyncVerdicts(emptyList(), emptyList(), emptyList()), SyncVerdicts.of(emptyList(), emptyList()))
    }
}