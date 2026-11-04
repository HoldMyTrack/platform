package dev.holdmytrack.android.recording

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** What a recording keeps (`apps/android/docs/SPEC.md` FR-5.1). */
class RecordingRulesTest {

    @Test
    fun `stop saves a recording of a minute and two points`() {
        assertTrue(RecordingRules.keeps(RecordingRules.MIN_DURATION_MS, 2))
        assertFalse(RecordingRules.keeps(RecordingRules.MIN_DURATION_MS - 1, 500))
        assertFalse(RecordingRules.keeps(3_600_000, 1))
    }

    /** Fixes on a line, so a step is the difference of two numbers. */
    private fun tally() = DistanceTally<Double> { a, b -> kotlin.math.abs(b - a) }

    @Test
    fun `each fix adds its step from the one before`() {
        val t = tally()
        listOf(0.0, 10.0, 25.0, 20.0).forEach(t::add)
        assertEquals(30.0, t.meters, 0.0)
    }

    @Test
    fun `no distance is counted across a pause`() {
        val t = tally()
        t.add(0.0)
        t.add(10.0)
        t.breakStep()
        t.add(1_000.0) // the phone travelled while paused
        t.add(1_005.0)
        assertEquals(15.0, t.meters, 0.0)
    }

    @Test
    fun `a leftover picked up again carries its distance and starts afresh`() {
        val t = tally()
        t.add(0.0)
        t.reset(500.0)
        t.add(2_000.0)
        t.add(2_010.0)
        assertEquals(510.0, t.meters, 0.0)
    }
}