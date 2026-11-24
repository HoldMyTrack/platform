package dev.holdmytrack.android.panel

import dev.holdmytrack.android.panel.SyncSourceRow.Line
import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncSourceRowTest {

    private val at = Instant.parse("2026-11-24T12:12:00Z")

    private fun line(on: Boolean = true, readable: Boolean = true, setUpNotice: Boolean = false, loading: Boolean = false, checkedAt: Instant? = at) =
        SyncSourceRow.line(on, readable, setUpNotice, loading, checkedAt)

    @Test
    fun `off, or with the set-up notice showing, there is no row`() {
        assertEquals(Line.Hidden, line(on = false))
        assertEquals(Line.Hidden, line(readable = false, setUpNotice = true))
    }

    @Test
    fun `unreadable with nothing to set up says so, with no Refresh`() {
        assertEquals(Line.NotSetUp, line(readable = false))
        assertFalse(SyncSourceRow.refreshShown(Line.NotSetUp))
    }

    @Test
    fun `readable, it says when it was read, or that a read is under way`() {
        assertEquals(Line.Read(at), line())
        assertEquals(Line.NotRead, line(checkedAt = null))
        assertEquals(Line.Reading, line(loading = true))
        for (shown in listOf(Line.Read(at), Line.NotRead, Line.Reading)) assertTrue(SyncSourceRow.refreshShown(shown))
    }
}
