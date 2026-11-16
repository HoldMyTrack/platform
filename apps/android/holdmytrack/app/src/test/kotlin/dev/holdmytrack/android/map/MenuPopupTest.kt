package dev.holdmytrack.android.map

import dev.holdmytrack.android.map.MenuHold.Action
import org.junit.Assert.assertEquals
import org.junit.Test

class MenuPopupTest {
    private fun next(isOpen: Boolean, held: Boolean, want: Boolean, canOpen: Boolean = true) = MenuHold.next(isOpen, held, want, canOpen)

    @Test
    fun `a hold opens a closed menu, and keeps one it holds`() {
        assertEquals(Action.OPEN_HELD, next(isOpen = false, held = false, want = true))
        assertEquals(Action.NONE, next(isOpen = true, held = true, want = true))
    }

    @Test
    fun `a menu the user opened is taken over, so it lets go of touches and closes after the step`() {
        assertEquals(Action.REOPEN_HELD, next(isOpen = true, held = false, want = true))
    }

    @Test
    fun `letting go closes only a held menu, never the user's own`() {
        assertEquals(Action.CLOSE, next(isOpen = true, held = true, want = false))
        assertEquals(Action.NONE, next(isOpen = true, held = false, want = false))
        assertEquals(Action.NONE, next(isOpen = false, held = false, want = false))
    }

    @Test
    fun `with nothing to show a hold waits`() {
        assertEquals(Action.NONE, next(isOpen = false, held = false, want = true, canOpen = false))
    }

    @Test
    fun `the button fills only while picks show, and the badge greys while the switch is off`() {
        assertEquals(RailLook(filled = true, badge = true, badgeAlpha = 1f, switchEnabled = true), RailLook.of(picked = 2, shown = true))
        assertEquals(RailLook(filled = false, badge = true, badgeAlpha = RailLook.OFF_ALPHA, switchEnabled = true), RailLook.of(picked = 2, shown = false))
        assertEquals(RailLook(filled = false, badge = false, badgeAlpha = 1f, switchEnabled = false), RailLook.of(picked = 0, shown = true))
    }
}
