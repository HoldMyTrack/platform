package dev.holdmytrack.android.map

import org.junit.Assert.assertEquals
import org.junit.Test

class EditorPlacementTest {

    @Test
    fun `the editors clear the gesture bar, or the keyboard while it's up`() {
        assertEquals(30 + 63, EditorPlacement.bottom(space = 30, gesture = 63, keyboard = 0))
        assertEquals(30 + 883, EditorPlacement.bottom(space = 30, gesture = 63, keyboard = 883))
    }

    @Test
    fun `the Edit window scrolls past part of the screen, or what the keyboard leaves`() {
        assertEquals(1320, EditorPlacement.scrollCap(screen = 2400, room = 2000, padding = 96))
        assertEquals(1000 - 96, EditorPlacement.scrollCap(screen = 2400, room = 1000, padding = 96))
        assertEquals(0, EditorPlacement.scrollCap(screen = 2400, room = 50, padding = 96))
    }
}