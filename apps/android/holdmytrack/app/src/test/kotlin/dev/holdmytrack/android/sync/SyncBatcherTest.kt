package dev.holdmytrack.android.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** How a sync's sessions are grouped into requests (`docs/SPEC.md` FR-3.6). */
class SyncBatcherTest {

    /** Adds each (name, points) and returns the requests sent, the leftover last. */
    private fun requests(items: List<Pair<String, Int>>, maxActivities: Int = 3, maxPoints: Int = 100): List<List<String>> {
        val batcher = SyncBatcher<String>(maxActivities, maxPoints)
        val sent = items.mapNotNull { (name, points) -> batcher.add(name, points) }
        return sent + listOf(batcher.rest()).filter { it.isNotEmpty() }
    }

    @Test
    fun `a request goes once it holds the most activities`() {
        assertEquals(listOf(listOf("a", "b", "c"), listOf("d")), requests(listOf("a" to 1, "b" to 1, "c" to 1, "d" to 1)))
    }

    @Test
    fun `a request goes once its points reach the most, the activity that filled it included`() {
        assertEquals(listOf(listOf("a", "b"), listOf("c")), requests(listOf("a" to 60, "b" to 40, "c" to 10)))
    }

    @Test
    fun `nothing sent leaves nothing over`() {
        assertEquals(emptyList<List<String>>(), requests(emptyList()))
        val batcher = SyncBatcher<String>()
        assertNull(batcher.add("a", 1))
        assertEquals(listOf("a"), batcher.rest())
        assertEquals(emptyList<String>(), batcher.rest())
    }

    @Test
    fun `a route past the server's ceiling isn't sent`() {
        assertFalse(SyncBatcher.tooLarge(SyncBatcher.MAX_POINTS_PER_ACTIVITY))
        assertTrue(SyncBatcher.tooLarge(SyncBatcher.MAX_POINTS_PER_ACTIVITY + 1))
    }
}