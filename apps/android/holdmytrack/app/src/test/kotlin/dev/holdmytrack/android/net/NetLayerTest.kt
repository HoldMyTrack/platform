package dev.holdmytrack.android.net

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * `net` is the API client and what the session needs, so the map, the panels and the screens
 * depend on it and never the other way (`apps/android/docs/IMPLEMENTATION.md` §2.1): what a response
 * means for them reaches them through a hook they set (`onTrackTypes`, `onRefusedBuild`,
 * `Session.onClear`).
 */
class NetLayerTest {

    @Test
    fun `net imports nothing of the app but its build config`() {
        // Unit tests run in the module's directory.
        val dir = File("src/main/kotlin/dev/holdmytrack/android/net")
        val files = dir.listFiles { f -> f.extension == "kt" }.orEmpty()
        check(files.isNotEmpty()) { "no sources under ${dir.absolutePath}" }
        val reaching = files.flatMap { file ->
            file.readLines()
                .filter { it.startsWith("import dev.holdmytrack.android.") }
                .filterNot { it.startsWith("import dev.holdmytrack.android.net.") || it == "import dev.holdmytrack.android.BuildConfig" }
                .map { "${file.name}: $it" }
        }
        assertEquals(emptyList<String>(), reaching)
    }
}
