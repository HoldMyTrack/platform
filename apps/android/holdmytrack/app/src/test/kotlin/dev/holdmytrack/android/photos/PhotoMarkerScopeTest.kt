package dev.holdmytrack.android.photos

import dev.holdmytrack.android.map.PhotoMarkerItem
import dev.holdmytrack.android.map.PhotoMarkerOverlay
import dev.holdmytrack.android.net.Photo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

class PhotoMarkerScopeTest {

    private fun photo(id: String, trackId: String = "a", lat: Double? = 59.43, lon: Double? = 24.75) =
        Photo(id, trackId, null, Instant.EPOCH, lon, lat, null, 1, 1, "u", "t/$id")

    @Test
    fun `markers leave out photos without a place and on hidden routes`() {
        val items = PhotoMarkerScope.markers(listOf(photo("p"), photo("q", lat = null), photo("r", trackId = "hidden")), setOf("hidden"), null)
        assertEquals(listOf("p"), items.map { it.id })
        assertEquals("t/p", items.single().thumbPath)
    }

    @Test
    fun `the Photos tab's unsaved changes are merged in`() {
        val moved = PhotoMarkerItem("p", 25.0, 60.0, null)
        val added = PhotoMarkerItem("new", 26.0, 61.0, null)
        val overlay = PhotoMarkerOverlay(upserts = listOf(moved, added), hidden = setOf("q"), activeId = "new")
        val items = PhotoMarkerScope.markers(listOf(photo("p"), photo("q")), emptySet(), overlay)
        assertEquals(listOf(moved, added), items)
    }

    @Test
    fun `markers hide while recording, on the Track tab and for a hidden route`() {
        assertTrue(PhotoMarkerScope.shown("track:a", recording = false, showingRoute = false, mapHidden = emptySet()))
        assertFalse(PhotoMarkerScope.shown("track:a", recording = true, showingRoute = false, mapHidden = emptySet()))
        assertFalse(PhotoMarkerScope.shown("track:a", recording = false, showingRoute = true, mapHidden = emptySet()))
        assertFalse(PhotoMarkerScope.shown("track:a", recording = false, showingRoute = false, mapHidden = setOf("a")))
        assertTrue(PhotoMarkerScope.shown("trip:a", recording = false, showingRoute = false, mapHidden = setOf("a")))
        assertFalse(PhotoMarkerScope.shown(null, recording = false, showingRoute = false, mapHidden = emptySet()))
    }
}
