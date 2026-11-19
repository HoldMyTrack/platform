package dev.holdmytrack.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class MainTabTest {

    @Test
    fun `a saved tab comes back by its name`() {
        assertEquals(MainActivity.Tab.TRACKS, MainActivity.Tab.named("TRACKS"))
        assertEquals(MainActivity.Tab.YOU, MainActivity.Tab.named("YOU"))
    }

    @Test
    fun `a name no tab has, such as an older build's MAP, is none`() {
        assertNull(MainActivity.Tab.named("MAP"))
        assertNull(MainActivity.Tab.named(""))
    }
}
