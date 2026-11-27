package dev.holdmytrack.android.panel

import dev.holdmytrack.android.net.Track
import dev.holdmytrack.android.panel.ToolbarRules.CheckAll
import dev.holdmytrack.android.panel.ToolbarRules.Head
import dev.holdmytrack.android.panel.ToolbarRules.Use
import org.junit.Assert.assertEquals
import org.junit.Test

class ToolbarRulesTest {

    private fun track(id: String, type: String, meters: Double?) = Track(
        id = id, startedAt = "2026-09-24T08:00:00Z", trackType = type, name = null, distanceMeters = meters,
        movingSeconds = 600, description = null, bbox = listOf(0.0, 0.0, 1.0, 1.0), pending = false, edited = false,
    )

    @Test
    fun `the head names one track by its type and distance`() =
        assertEquals(Head("cycling", 1, 10300.0), ToolbarRules.head(listOf(track("a", "cycling", 10300.0)), checked = false))

    @Test
    fun `a private track has no distance to name`() =
        assertEquals(Head("walking", 1, null), ToolbarRules.head(listOf(track("a", "walking", null)), checked = false))

    @Test
    fun `a checked group, one track or more, is its count and total`() {
        assertEquals(Head(null, 1, 1000.0), ToolbarRules.head(listOf(track("a", "walking", 1000.0)), checked = true))
        assertEquals(Head(null, 2, 3000.0), ToolbarRules.head(listOf(track("a", "walking", 1000.0), track("b", "running", 2000.0)), checked = true))
    }

    @Test
    fun `nothing targeted, everything says so`() {
        val a = ToolbarRules.actions(targets = 0, anyPending = false, demo = false)
        assertEquals(List(6) { Use.NO_TARGET }, listOf(a.visibility, a.edit, a.addToTrip, a.info, a.delete, a.focus))
    }

    @Test
    fun `the demo can look, not change`() {
        val a = ToolbarRules.actions(targets = 2, anyPending = false, demo = true)
        assertEquals(Use.READY, a.visibility)
        assertEquals(Use.READY, a.focus)
        assertEquals(Use.READY, a.info)
        assertEquals(listOf(Use.DEMO, Use.DEMO, Use.DEMO), listOf(a.edit, a.addToTrip, a.delete))
    }

    @Test
    fun `a pending row blocks only delete`() {
        val a = ToolbarRules.actions(targets = 3, anyPending = true, demo = false)
        assertEquals(Use.PENDING, a.delete)
        assertEquals(List(5) { Use.READY }, listOf(a.visibility, a.edit, a.addToTrip, a.info, a.focus))
        // The demo's reason comes first: it couldn't delete either way.
        assertEquals(Use.DEMO, ToolbarRules.actions(targets = 3, anyPending = true, demo = true).delete)
    }

    @Test
    fun `the master checkbox`() {
        assertEquals(CheckAll.NONE, ToolbarRules.checkAll(listed = 0, checked = 0))
        assertEquals(CheckAll.NONE, ToolbarRules.checkAll(listed = 4, checked = 0))
        assertEquals(CheckAll.SOME, ToolbarRules.checkAll(listed = 4, checked = 2))
        assertEquals(CheckAll.ALL, ToolbarRules.checkAll(listed = 4, checked = 4))
    }
}
