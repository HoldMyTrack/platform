package dev.holdmytrack.android.panel

import dev.holdmytrack.android.panel.ToolbarRules.CheckAll
import dev.holdmytrack.android.panel.ToolbarRules.Use
import org.junit.Assert.assertEquals
import org.junit.Test

class ToolbarRulesTest {

    @Test
    fun `nothing targeted, everything says so`() {
        val a = ToolbarRules.actions(targets = 0, anyPending = false, demo = false)
        assertEquals(listOf(Use.NO_TARGET, Use.NO_TARGET, Use.NO_TARGET, Use.NO_TARGET, Use.NO_TARGET), listOf(a.visibility, a.edit, a.addToStory, a.delete, a.focus))
    }

    @Test
    fun `the demo can look, not change`() {
        val a = ToolbarRules.actions(targets = 2, anyPending = false, demo = true)
        assertEquals(Use.READY, a.visibility)
        assertEquals(Use.READY, a.focus)
        assertEquals(listOf(Use.DEMO, Use.DEMO, Use.DEMO), listOf(a.edit, a.addToStory, a.delete))
    }

    @Test
    fun `a pending row blocks only delete`() {
        val a = ToolbarRules.actions(targets = 3, anyPending = true, demo = false)
        assertEquals(Use.PENDING, a.delete)
        assertEquals(listOf(Use.READY, Use.READY, Use.READY, Use.READY), listOf(a.visibility, a.edit, a.addToStory, a.focus))
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
