package dev.holdmytrack.android.recording

import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The recording in progress: moving time, distance, pauses, leftovers and ownership
 *  (`apps/docs/SPEC.md` FR-5.1). */
class RecordingSessionTest {

    /** Fixes on a line, so a step is the difference of two numbers; times are `elapsedRealtime`. */
    private fun session() = RecordingSession<Double> { a, b -> kotlin.math.abs(b - a) }

    private fun point(x: Double) = RecordedPoint(lat = x, lon = 0.0, elevationM = null, time = Instant.ofEpochSecond(x.toLong()))

    private fun RecordingSession<Double>.fix(x: Double, nowMs: Long) = add(x, point(x), nowMs)

    @Test
    fun `moving time runs from start and leaves out pauses`() {
        val s = session()
        s.start("r", "a@x", nowMs = 1_000)
        assertEquals(4_000, s.movingMs(5_000))
        s.toggle(6_000) // pause after 5 s
        assertEquals(5_000, s.movingMs(60_000))
        s.toggle(60_000) // resume after a 54 s pause
        assertEquals(7_000, s.movingMs(62_000))
    }

    @Test
    fun `a pause hands the journal the totals so far`() {
        val s = session()
        s.start("r", "a@x", nowMs = 0)
        s.fix(0.0, 1_000)
        s.fix(30.0, 2_000)
        assertEquals(RecordingSession.Totals("r", 3_000, 30.0), s.toggle(3_000))
        assertNull(s.toggle(4_000)) // resuming journals nothing
    }

    @Test
    fun `fixes while paused are not kept`() {
        val s = session()
        s.start("r", "a@x", nowMs = 0)
        s.fix(0.0, 1_000)
        s.toggle(2_000)
        assertNull(s.fix(50.0, 3_000)) // GPS drift from a phone on a table
        assertEquals(1, s.points().size)
        assertEquals(0.0, s.distanceM, 0.0)
    }

    @Test
    fun `the first fix after a resume adds no step from before the pause`() {
        val s = session()
        s.start("r", "a@x", nowMs = 0)
        s.fix(0.0, 1_000)
        s.fix(10.0, 2_000)
        s.toggle(3_000)
        s.toggle(10_000) // the phone travelled while paused
        s.fix(1_000.0, 11_000)
        s.fix(1_005.0, 12_000)
        assertEquals(15.0, s.distanceM, 0.0)
    }

    @Test
    fun `each fix is appended with the next sequence number and the running totals`() {
        val s = session()
        s.start("r", "a@x", nowMs = 0)
        s.fix(0.0, 1_000)
        val second = s.fix(20.0, 4_000)!!
        assertEquals(RecordingSession.Appended("r", 1, point(20.0), 4_000, 20.0), second)
    }

    @Test
    fun `stop hands over the recording and leaves the session idle`() {
        val s = session()
        s.start("r", "a@x", nowMs = 0)
        s.fix(0.0, 10_000)
        s.fix(40.0, 70_000)
        val done = s.stop(90_000)!!
        assertEquals(RecordingSession.Finished("r", "a@x", 90_000, 40.0, listOf(point(0.0), point(40.0))), done)
        assertEquals(RecordingState.IDLE, s.state)
        assertTrue(s.points().isEmpty())
        assertNull(s.stop(91_000))
        assertNull(s.fix(50.0, 92_000))
    }

    @Test
    fun `stop while paused counts no moving time after the pause`() {
        val s = session()
        s.start("r", "a@x", nowMs = 0)
        s.toggle(30_000)
        assertEquals(30_000, s.stop(500_000)!!.movingMs)
    }

    @Test
    fun `a leftover comes back paused, the time the process was dead uncounted`() {
        val s = session()
        val kept = listOf(point(0.0), point(10.0), point(25.0))
        assertTrue(s.resume("old", "a@x", kept, movingMs = 120_000, distanceM = 25.0))
        assertEquals(RecordingState.PAUSED, s.state)
        assertEquals(120_000, s.movingMs(9_999_999))

        s.toggle(1_000_000)
        val next = s.fix(500.0, 1_001_000)!!
        // Its sequence follows the journal's three points; the jump from 25 to 500 isn't distance.
        assertEquals(3, next.seq)
        assertEquals(25.0, next.distanceM, 0.0)
        assertEquals(121_000, next.movingMs)
        assertEquals("old", next.id)
    }

    @Test
    fun `a leftover isn't picked up over a recording under way`() {
        val s = session()
        s.start("r", "a@x", nowMs = 0)
        assertFalse(s.resume("old", "a@x", emptyList(), 0, 0.0))
        assertEquals("r", s.id)
        assertEquals(RecordingState.RECORDING, s.state)
    }

    @Test
    fun `a new start forgets the last recording`() {
        val s = session()
        s.start("r1", "a@x", nowMs = 0)
        s.fix(0.0, 1_000)
        s.fix(100.0, 2_000)
        s.stop(3_000)
        s.start("r2", "b@x", nowMs = 10_000)
        assertEquals(0, s.movingMs(10_000))
        assertEquals(0.0, s.distanceM, 0.0)
        s.fix(7.0, 11_000)
        assertEquals(0.0, s.distanceM, 0.0) // no step from r1's last fix
        assertEquals("b@x", s.account)
    }

    @Test
    fun `a deleted account's recording is discarded, anyone else's is not`() {
        val s = session()
        s.start("r", "a@x", nowMs = 0)
        assertFalse(s.discard("b@x"))
        assertFalse(s.discard(null))
        assertEquals(RecordingState.RECORDING, s.state)
        assertTrue(s.discard("a@x"))
        assertEquals(RecordingState.IDLE, s.state)
        assertTrue(s.points().isEmpty())
        assertFalse(s.discard("a@x"))
    }

    @Test
    fun `going away mid-recording journals the totals, paused or idle nothing`() {
        val s = session()
        assertNull(s.checkpoint(0))
        s.start("r", "a@x", nowMs = 0)
        assertEquals(RecordingSession.Totals("r", 5_000, 0.0), s.checkpoint(5_000))
        s.toggle(6_000)
        assertNull(s.checkpoint(7_000))
    }

    @Test
    fun `pause and resume do nothing when idle`() {
        val s = session()
        assertNull(s.toggle(1_000))
        assertEquals(RecordingState.IDLE, s.state)
    }
}
