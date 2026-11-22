package dev.holdmytrack.android.panel

import dev.holdmytrack.android.net.Track
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The Edit window's Track and Photos tabs (root `docs/SPEC.md` FR-5.7, FR-15.1). */
class EditAvailabilityTest {

    private fun track(id: String = "a", routeEdit: String? = null, photos: String? = null) = Track(
        id = id, startedAt = "2026-09-24T08:00:00Z", trackType = "walking", name = null,
        distanceMeters = 1000.0, movingSeconds = 600, description = null, bbox = listOf(0.0, 0.0, 1.0, 1.0),
        pending = false, edited = false, routeEdit = routeEdit, photos = photos,
    )

    @Test
    fun `the Track tab needs one track the server allows`() {
        assertEquals(EditBlock.CHECK_ONE, EditAvailability.track(emptyList()))
        assertEquals(EditBlock.CHECK_ONE, EditAvailability.track(listOf(track(), track("b"))))
        assertEquals(EditBlock.PENDING, EditAvailability.track(listOf(track(routeEdit = "pending"))))
        assertEquals(EditBlock.PRIVATE, EditAvailability.track(listOf(track(routeEdit = "private"))))
        assertEquals(EditBlock.NO_ORIGINAL, EditAvailability.track(listOf(track(routeEdit = "no_original"))))
        assertEquals(EditBlock.BAD_TIMES, EditAvailability.track(listOf(track(routeEdit = "bad_times"))))
        assertNull(EditAvailability.track(listOf(track())))
        assertNull(EditAvailability.track(listOf(track(routeEdit = "from_a_newer_server"))))
    }

    @Test
    fun `photos need one track the server allows`() {
        assertEquals(EditBlock.CHECK_ONE, EditAvailability.photos(listOf(track(), track("b"))))
        assertEquals(EditBlock.PRIVATE, EditAvailability.photos(listOf(track(photos = "private"))))
        assertNull(EditAvailability.photos(listOf(track(routeEdit = "pending"))))
    }

    @Test
    fun `a tap on a blocked tab gives its own reason and the Track tab always opens`() {
        assertEquals("one", EditAvailability.tapped(EditTab.ROUTE, route = "one", photos = "photos"))
        assertEquals("photos", EditAvailability.tapped(EditTab.PHOTOS, route = "one", photos = "photos"))
        assertNull(EditAvailability.tapped(EditTab.TRACK, route = "one", photos = "photos"))
        assertNull(EditAvailability.tapped<String>(EditTab.ROUTE, route = null, photos = "photos"))
    }
}
