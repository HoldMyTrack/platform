package dev.holdmytrack.android

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Another app can open the main window but not steer it. */
class MainEntryTest {

    @Test
    fun `a launch through the app's own alias is acted on`() {
        assertTrue(MainEntry.fromApp(MainEntry.ALIAS))
    }

    @Test
    fun `a launch of the exported activity is not`() {
        assertFalse(MainEntry.fromApp(MainActivity::class.java.name))
        assertFalse(MainEntry.fromApp(null))
    }
}
