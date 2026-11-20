package dev.holdmytrack.android.panel

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncRowRulesTest {
    private val row = SyncRow(
        key = "recording:1", title = "Walk", meta = "", note = null, processing = false, similar = 0,
        type = "walking", recording = true, ticked = false, hidden = false, highlighted = false,
    )

    @Test
    fun `a row waiting can be ticked`() {
        assertTrue(SyncRowRules.tickable(row, demo = false))
    }

    @Test
    fun `a hidden row, one on its way, or any for the demo account can't`() {
        assertFalse(SyncRowRules.tickable(row.copy(hidden = true), demo = false))
        assertFalse(SyncRowRules.tickable(row.copy(processing = true), demo = false))
        assertFalse(SyncRowRules.tickable(row, demo = true))
    }

    @Test
    fun `only a recording still on the phone can be edited or deleted`() {
        assertTrue(SyncRowRules.editable(row))
        assertFalse(SyncRowRules.editable(row.copy(processing = true)))
        assertFalse(SyncRowRules.editable(row.copy(key = "health_connect:1", recording = false)))
    }
}
