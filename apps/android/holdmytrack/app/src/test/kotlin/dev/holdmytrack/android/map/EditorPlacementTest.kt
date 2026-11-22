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
    fun `a card that can't scroll rises only as far as keeps its top on screen`() {
        // Room for all of it above the keyboard.
        assertEquals(913, EditorPlacement.fitted(bottom = 913, floor = 93, screen = 2400, card = 700, top = 200))
        // A landscape screen: its top would go past the top row, so it rises less.
        assertEquals(1080 - 500 - 150, EditorPlacement.fitted(bottom = 600, floor = 93, screen = 1080, card = 500, top = 150))
        // Never down into the gesture bar, nor held back before it's laid out.
        assertEquals(93, EditorPlacement.fitted(bottom = 600, floor = 93, screen = 700, card = 600, top = 150))
        assertEquals(600, EditorPlacement.fitted(bottom = 600, floor = 93, screen = 1080, card = 0, top = 150))
    }

    @Test
    fun `the Edit sheet reaches the screen's edge, or rides on the keyboard`() {
        assertEquals(EditorPlacement.Sheet(margin = 0, padding = 63), EditorPlacement.sheet(gesture = 63, keyboard = 0))
        assertEquals(EditorPlacement.Sheet(margin = 883, padding = 0), EditorPlacement.sheet(gesture = 63, keyboard = 883))
    }

    @Test
    fun `the Edit sheet takes part of the screen, or what the keyboard leaves, its fields down to one field`() {
        // The whole sheet within 55% of the screen: its header and paddings come off the fields.
        assertEquals(1320 - 200, EditorPlacement.scrollCap(screen = 2400, room = 2000, chrome = 200, min = 252))
        assertEquals(1000 - 200, EditorPlacement.scrollCap(screen = 2400, room = 1000, chrome = 200, min = 252))
        // A short screen with the keyboard up, or a large font: one field still shows.
        assertEquals(252, EditorPlacement.scrollCap(screen = 2400, room = 150, chrome = 200, min = 252))
    }
}