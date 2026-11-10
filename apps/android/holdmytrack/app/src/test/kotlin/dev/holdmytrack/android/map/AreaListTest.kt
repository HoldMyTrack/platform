package dev.holdmytrack.android.map

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

/** The area list and Dates (`docs/SPEC.md` FR-5.19, FR-5.20) beyond their shared rules. */
class AreaListTest {

    private val lateEvening = Instant.parse("2026-09-12T23:30:00Z")

    @Test
    fun `today is the day in the account's zone`() {
        assertEquals("2026-09-13", DateFilter.today("Asia/Tokyo", lateEvening))
        assertEquals("2026-09-12", DateFilter.today("America/New_York", lateEvening))
    }

    @Test
    fun `an unknown zone falls back to the phone's`() {
        assertTrue(DateFilter.today("Mars/Olympus_Mons", lateEvening).matches(Regex("""\d{4}-\d{2}-\d{2}""")))
    }

    @Test
    fun `the view is asked about to a metre`() {
        assertEquals(listOf(-81.12346, 41.0, -81.0, 41.5), AreaLoad.box(-81.123456, 41.000004, -81.0, 41.5))
        assertTrue(AreaLoad.same(listOf(8.0, 47.0, 9.0, 48.0), listOf(8.000001, 47.0, 9.0, 48.0)))
        assertFalse(AreaLoad.same(listOf(8.0, 47.0, 9.0, 48.0), listOf(8.0001, 47.0, 9.0, 48.0)))
        assertFalse(AreaLoad.same(null, listOf(8.0, 47.0, 9.0, 48.0)))
    }

    @Test
    fun `all time is no end set`() {
        assertTrue(DateFilter.ALL_TIME.isAllTime)
        assertFalse(DateFilter(after = "2026-06-03").isAllTime)
    }
}
