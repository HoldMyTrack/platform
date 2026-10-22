package dev.holdmytrack.android.sync

import org.junit.Assert.assertEquals
import org.junit.Test

class SyncOutcomeTest {

    @Test
    fun `processing waits, known landed, neither failed`() {
        val known = setOf("a", "b")
        val processing = setOf("b", "c")
        assertEquals(Outcome.LANDED, syncOutcome("a", known, processing))
        assertEquals(null, syncOutcome("b", known, processing))
        assertEquals(null, syncOutcome("c", known, processing))
        assertEquals(Outcome.FAILED, syncOutcome("d", known, processing))
    }
}
