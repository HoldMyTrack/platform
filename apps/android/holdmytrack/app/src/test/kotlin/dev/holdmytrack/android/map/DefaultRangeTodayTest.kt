package dev.holdmytrack.android.map

import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** "Today" is the account's calendar day (`docs/SPEC.md` FR-1.7), read when asked. */
class DefaultRangeTodayTest {

    private val lateEvening = Instant.parse("2026-09-12T23:30:00Z")

    @Test
    fun `today is the day in the account's zone`() {
        assertEquals("2026-09-13", DefaultRange.today("Asia/Tokyo", lateEvening))
        assertEquals("2026-09-12", DefaultRange.today("America/New_York", lateEvening))
    }

    @Test
    fun `an unknown zone falls back to the phone's`() {
        assertTrue(DefaultRange.today("Mars/Olympus_Mons", lateEvening).matches(Regex("""\d{4}-\d{2}-\d{2}""")))
    }
}