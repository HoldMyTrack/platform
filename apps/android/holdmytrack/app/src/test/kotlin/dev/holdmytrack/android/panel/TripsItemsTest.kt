package dev.holdmytrack.android.panel

import dev.holdmytrack.android.net.Track
import dev.holdmytrack.android.net.Trip
import dev.holdmytrack.android.net.TripTotals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class TripsItemsTest {
    private val words = TripsWords(loading = "Loading…", noneMatch = "None match", empty = "No trips", from = { "From $it" })

    private fun trip(id: String, tracks: Int = 2) =
        Trip(id, "Trip $id", "About $id", trackIds = List(tracks) { "$id-$it" }, stats = TripTotals("", tracks, 1000.0, 60), byType = emptyList())

    private fun row(id: String) = TrackRowItem(
        Track(id, "2026-11-01T10:00:00Z", "walk", name = null, distanceMeters = 1000.0, movingSeconds = 60, description = null, bbox = null, pending = false, edited = false),
        checked = false, focused = false, hidden = false,
    )

    @Test
    fun theListAndTheOpenTripsRowsLoadingAreDifferentItems() {
        val before = TripsItems.of(TripsState(), words)
        val after = TripsItems.of(TripsState(trips = listOf(trip("a"), trip("b")), ready = true, openId = "a", rowsLoading = true), words)
        val listLoading = before.single() as TripsItem.Note
        val rowsLoading = after.filterIsInstance<TripsItem.Note>().single()
        assertEquals(listLoading.text, rowsLoading.text)
        assertNotEquals(listLoading.key, rowsLoading.key)
    }

    @Test
    fun theOpenTripsFolderComesFirstThenItsDescriptionStatsAndRows() {
        val items = TripsItems.of(TripsState(trips = listOf(trip("a"), trip("b")), ready = true, openId = "a", rows = listOf(row("r1"), row("r2"))), words)
        assertEquals(
            listOf("folder:a", "description:a", "stats:a", "row:r1", "row:r2", "folder:b"),
            items.map { it.key },
        )
    }

    @Test
    fun everyKeyIsUnique() {
        val state = TripsState(
            trips = listOf(trip("a"), trip("b")), ready = true, openId = "a", answerError = "Failed",
            openError = "Failed", removeError = "Failed", rowsError = "Failed", error = "Failed",
        )
        val keys = TripsItems.of(state, words).map { it.key }
        assertEquals(keys.distinct(), keys)
    }

    @Test
    fun aFoldedTripShowsOnlyItsFolder() {
        val items = TripsItems.of(TripsState(trips = listOf(trip("a")), ready = true, openId = "a", foldedId = "a", rows = listOf(row("r1"))), words)
        assertEquals(listOf("folder:a"), items.map { it.key })
    }
}