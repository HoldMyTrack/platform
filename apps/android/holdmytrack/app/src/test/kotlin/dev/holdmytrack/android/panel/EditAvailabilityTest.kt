package dev.holdmytrack.android.panel

import dev.holdmytrack.android.net.Activity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The Edit window's Track and Photos tabs (root `docs/SPEC.md` FR-5.14, FR-16.1). */
class EditAvailabilityTest {

    private fun activity(id: String = "a", trackEdit: String? = null, photos: String? = null) = Activity(
        id = id, startedAt = "2026-09-24T08:00:00Z", activityType = "walking", name = null,
        distanceMeters = 1000.0, durationSeconds = 600, description = null, bbox = listOf(0.0, 0.0, 1.0, 1.0),
        pending = false, edited = false, trackEdit = trackEdit, photos = photos,
    )

    @Test
    fun `the Track tab needs one activity the server allows`() {
        assertEquals(EditBlock.CHECK_ONE, EditAvailability.track(emptyList()))
        assertEquals(EditBlock.CHECK_ONE, EditAvailability.track(listOf(activity(), activity("b"))))
        assertEquals(EditBlock.PENDING, EditAvailability.track(listOf(activity(trackEdit = "pending"))))
        assertEquals(EditBlock.PRIVATE, EditAvailability.track(listOf(activity(trackEdit = "private"))))
        assertEquals(EditBlock.NO_ORIGINAL, EditAvailability.track(listOf(activity(trackEdit = "no_original"))))
        assertEquals(EditBlock.BAD_TIMES, EditAvailability.track(listOf(activity(trackEdit = "bad_times"))))
        assertNull(EditAvailability.track(listOf(activity())))
        assertNull(EditAvailability.track(listOf(activity(trackEdit = "from_a_newer_server"))))
    }

    @Test
    fun `photos need one activity the server allows`() {
        assertEquals(EditBlock.CHECK_ONE, EditAvailability.photos(listOf(activity(), activity("b"))))
        assertEquals(EditBlock.PRIVATE, EditAvailability.photos(listOf(activity(photos = "private"))))
        assertNull(EditAvailability.photos(listOf(activity(trackEdit = "pending"))))
    }
}
