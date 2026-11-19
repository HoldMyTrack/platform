package dev.holdmytrack.android.net

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `net` is the API client and what the session needs, so the map, the panels and the screens
 * depend on it and never the other way (`apps/android/docs/IMPLEMENTATION.md` §2.1): what a response
 * means for them reaches them through a hook they set (`onTrackTypes`, `onRefusedBuild`,
 * `Session.onClear`).
 */
class NetLayerTest {

    @Test
    fun `net names nothing of the app but its build config`() {
        // Unit tests run in the module's directory.
        val dir = File("src/main/kotlin/dev/holdmytrack/android/net")
        val files = dir.walkTopDown().filter { it.isFile && it.extension == "kt" }.toList()
        check(files.isNotEmpty()) { "no sources under ${dir.absolutePath}" }
        val reaching = files.flatMap { file ->
            file.readLines().filter(::crosses).map { "${file.relativeTo(dir)}: ${it.trim()}" }
        }
        assertEquals(emptyList<String>(), reaching)
    }

    @Test
    fun `a full name crosses as an import does`() {
        assertTrue(crosses("import dev.holdmytrack.android.panel.TrackTypes"))
        assertTrue(crosses("        dev.holdmytrack.android.panel.TrackTypes.merge(types)"))
        assertTrue(crosses("import dev.holdmytrack.android.UpdateAppActivity"))
        assertFalse(crosses("package dev.holdmytrack.android.net"))
        assertFalse(crosses("import dev.holdmytrack.android.net.Session"))
        assertFalse(crosses("import dev.holdmytrack.android.BuildConfig"))
        assertFalse(crosses("import android.net.Uri"))
    }

    /** Whether [line] names a part of the app outside `net`, by import or in full. */
    private fun crosses(line: String): Boolean = OUTSIDE.containsMatchIn(line)

    private companion object {
        val OUTSIDE = Regex("""\bdev\.holdmytrack\.android\.(?!net\b|BuildConfig\b)\w""")
    }
}
