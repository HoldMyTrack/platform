package dev.holdmytrack.android.map

import org.junit.Assert.assertEquals
import org.junit.Test

class EditorPlacementTest {

    @Test
    fun `an editor reaches the screen's edge, or rides on the keyboard`() {
        assertEquals(EditorPlacement.Sheet(margin = 0, padding = 63), EditorPlacement.sheet(gesture = 63, keyboard = 0))
        assertEquals(EditorPlacement.Sheet(margin = 883, padding = 0), EditorPlacement.sheet(gesture = 63, keyboard = 883))
    }

    @Test
    fun `an editor takes part of the screen, or what the keyboard leaves, its fields down to one field`() {
        // The whole sheet within 55% of the screen: its header and paddings come off the fields.
        assertEquals(1320 - 200, EditorPlacement.scrollCap(screen = 2400, room = 2000, chrome = 200, min = 252))
        assertEquals(1000 - 200, EditorPlacement.scrollCap(screen = 2400, room = 1000, chrome = 200, min = 252))
        // A short screen with the keyboard up, or a large font: one field still shows.
        assertEquals(252, EditorPlacement.scrollCap(screen = 2400, room = 150, chrome = 200, min = 252))
    }
}