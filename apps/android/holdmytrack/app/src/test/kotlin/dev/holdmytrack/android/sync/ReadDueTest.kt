package dev.holdmytrack.android.sync

import java.time.Instant
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReadDueTest {

    private val now = Instant.parse("2026-11-24T10:00:00Z")

    @Test
    fun `opening Sync reads at most once a minute`() {
        assertTrue(ReadDue.onOpen(firstLoadPending = false, lastRead = null, now = now))
        assertFalse(ReadDue.onOpen(firstLoadPending = false, lastRead = now.minusSeconds(59), now = now))
        assertTrue(ReadDue.onOpen(firstLoadPending = false, lastRead = now.minusSeconds(60), now = now))
    }

    @Test
    fun `a source just switched on is read whenever it was last read`() {
        assertTrue(ReadDue.onOpen(firstLoadPending = true, lastRead = now, now = now))
    }
}
