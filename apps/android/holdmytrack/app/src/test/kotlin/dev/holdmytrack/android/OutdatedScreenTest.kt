package dev.holdmytrack.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Update screen opens once per refusal, and never into the background (FR-1.8). */
class OutdatedScreenTest {

    @Test
    fun `a refusal with a screen in front opens it`() {
        val step = OutdatedScreen().refusedWhile(inFront = true)
        assertTrue(step.open)
        assertTrue(step.state.showing)
    }

    @Test
    fun `a burst of refusals opens it once`() {
        val first = OutdatedScreen().refusedWhile(inFront = true)
        assertFalse(first.state.refusedWhile(inFront = true).open)
    }

    @Test
    fun `a refusal in the background waits for the next screen in front`() {
        val background = OutdatedScreen().refusedWhile(inFront = false)
        assertFalse(background.open)
        val back = background.state.cameToFront(isUpdateScreen = false)
        assertTrue(back.open)
        assertFalse(back.state.cameToFront(isUpdateScreen = false).open)
    }

    @Test
    fun `the Update screen itself coming to the front opens nothing`() {
        val waiting = OutdatedScreen().refusedWhile(inFront = false).state
        assertFalse(waiting.cameToFront(isUpdateScreen = true).open)
    }

    @Test
    fun `nothing opens without a refusal`() {
        assertFalse(OutdatedScreen().cameToFront(isUpdateScreen = false).open)
    }

    @Test
    fun `closing it lets the next refusal open it again`() {
        val shown = OutdatedScreen().refusedWhile(inFront = true).state
        assertEquals(OutdatedScreen(), shown.closed())
        assertTrue(shown.closed().refusedWhile(inFront = true).open)
    }
}
