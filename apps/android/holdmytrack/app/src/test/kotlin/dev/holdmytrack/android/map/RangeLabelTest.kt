package dev.holdmytrack.android.map

import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.LocalDate
import java.util.Locale

class RangeLabelTest {

    @Test
    fun theRangeSaysItsYearOnce() {
        fun label(from: String, to: String) = RangeLabel.of(LocalDate.parse(from), LocalDate.parse(to), Locale.ENGLISH)
        assertEquals("3 Oct 2026", label("2026-10-03", "2026-10-03"))
        assertEquals("24 – 28 Sep 2026", label("2026-09-24", "2026-09-28"))
        assertEquals("24 Sep – 3 Oct 2026", label("2026-09-24", "2026-10-03"))
        assertEquals("28 Dec 2025 – 3 Jan 2026", label("2025-12-28", "2026-01-03"))
    }
}
