package dev.holdmytrack.android.imports

import android.content.Intent
import java.net.URI
import org.junit.Assert.assertEquals
import org.junit.Test

/** What another app's intent puts on the Upload screen (`apps/docs/SPEC.md` FR-3.6). */
class SharedFilesTest {

    private val ride = URI("content://drive/ride.gpx")
    private val walk = URI("content://drive/walk.tcx")

    private fun of(action: String?, opened: URI?, shared: List<URI> = emptyList()) =
        SharedFiles.of(action, opened, shared) { it.scheme }

    @Test
    fun `an opened file is the intent's data`() {
        assertEquals(listOf(ride), of(Intent.ACTION_VIEW, ride, listOf(walk)))
    }

    @Test
    fun `shared files are the intent's streams`() {
        assertEquals(listOf(walk), of(Intent.ACTION_SEND, ride, listOf(walk)))
        assertEquals(listOf(ride, walk), of(Intent.ACTION_SEND_MULTIPLE, null, listOf(ride, walk)))
    }

    @Test
    fun `a file path is dropped`() {
        assertEquals(listOf(walk), of(Intent.ACTION_SEND_MULTIPLE, null, listOf(URI("file:///data/data/x/prefs.xml"), walk)))
        assertEquals(emptyList<URI>(), of(Intent.ACTION_VIEW, URI("file:///sdcard/ride.gpx")))
    }

    @Test
    fun `any other launch brings no files`() {
        assertEquals(emptyList<URI>(), of(null, ride, listOf(walk)))
        assertEquals(emptyList<URI>(), of(Intent.ACTION_MAIN, ride))
    }
}
