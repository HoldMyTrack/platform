package dev.holdmytrack.android.profile

import dev.holdmytrack.android.profile.YouRefresh.Mark
import dev.holdmytrack.android.profile.YouRefresh.Reads
import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Test

/** The You tab reads again only what could have changed. */
class YouRefreshTest {

    private val today = LocalDate.of(2026, 11, 19)
    private val last = Mark(atMs = 1_000_000, tileVersion = "v1", today = today)
    private fun later(ms: Long, version: String = "v1", day: LocalDate = today) = Mark(last.atMs + ms, version, day)

    @Test
    fun `the first show reads everything`() {
        assertEquals(Reads(true, true), YouRefresh.of(null, null, later(0), resumed = false))
    }

    @Test
    fun `a tab switch soon after reads nothing`() {
        assertEquals(Reads(false, false), YouRefresh.of(last, last.atMs, later(60_000), resumed = false))
    }

    @Test
    fun `a return to the app reads both`() {
        assertEquals(Reads(true, true), YouRefresh.of(last, last.atMs, later(60_000), resumed = true))
    }

    @Test
    fun `changed tracks read the numbers again`() {
        assertEquals(Reads(false, true), YouRefresh.of(last, last.atMs, later(60_000, version = "v2"), resumed = false))
    }

    @Test
    fun `a new day reads the numbers again`() {
        assertEquals(Reads(false, true), YouRefresh.of(last, last.atMs, later(60_000, day = today.plusDays(1)), resumed = false))
    }

    @Test
    fun `the numbers keep their own age`() {
        val numbersOld = Mark(last.atMs - YouRefresh.MAX_AGE_MS, "v1", today)
        assertEquals(Reads(false, true), YouRefresh.of(numbersOld, last.atMs, later(0), resumed = false))
    }

    @Test
    fun `old reads are all made again`() {
        assertEquals(Reads(true, true), YouRefresh.of(last, last.atMs, later(YouRefresh.MAX_AGE_MS), resumed = false))
    }
}
