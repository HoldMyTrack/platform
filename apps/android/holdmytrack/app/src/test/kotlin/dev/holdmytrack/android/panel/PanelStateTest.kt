package dev.holdmytrack.android.panel

import dev.holdmytrack.android.net.Track
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Tracks panel's rules (`apps/docs/SPEC.md` FR-2.7). */
class PanelStateTest {

    private fun track(id: String, type: String = "walking", meters: Double? = 1000.0, pending: Boolean = false) =
        Track(
            id = id,
            startedAt = "2026-09-24T08:00:00Z",
            trackType = type,
            name = null,
            distanceMeters = meters,
            movingSeconds = 600,
            description = null,
            bbox = listOf(0.0, 0.0, 1.0, 1.0),
            pending = pending,
            edited = false,
        )

    private val walk = track("a", "walking", 1200.0)
    private val run = track("b", "running", 10400.0)
    private val ride = track("c", "cycling", 21000.0)

    private fun state(vararg tracks: Track) = PanelState().apply { setTracks(tracks.toList()) }

    @Test
    fun `the toolbar acts on the checked group, else the selected row`() {
        val s = state(walk, run, ride)
        assertEquals(emptySet<String>(), s.targetIds)
        s.focus("b")
        assertEquals(setOf("b"), s.targetIds)
        s.toggleChecked("a")
        assertEquals(setOf("a", "b"), s.targetIds)
        s.toggleChecked("b")
        assertEquals(setOf("a"), s.targetIds)
    }

    @Test
    fun `check all and invert only reach the listed rows`() {
        val s = state(walk, run, ride)
        s.toggleType("cycling")
        s.checkAll()
        assertEquals(setOf("a", "b"), s.checked)
        s.toggleChecked("a")
        s.invertChecked()
        assertEquals(setOf("a"), s.checked)
    }

    @Test
    fun `show and hide makes the whole target one state`() {
        val s = state(walk, run)
        s.toggleChecked("a")
        s.toggleTargetVisibility()
        assertEquals(setOf("a"), s.hidden)
        s.toggleChecked("b")
        s.toggleTargetVisibility()
        assertEquals(emptySet<String>(), s.hidden)
        s.toggleTargetVisibility()
        assertEquals(setOf("a", "b"), s.hidden)
    }

    @Test
    fun `the map hides filtered-out, hidden and pending tracks`() {
        val pending = track("e", pending = true)
        val s = state(walk, run, ride, pending)
        s.toggleType("cycling")
        s.focus("a")
        s.toggleTargetVisibility()
        assertEquals(setOf("a", "c", "e"), s.mapHidden)
        assertEquals(listOf("a", "b", "e"), s.listed.map { it.id })
    }

    @Test
    fun `targets filtered out of the list disable the toolbar`() {
        val s = state(walk, ride)
        s.focus("c")
        s.toggleType("cycling")
        assertEquals(setOf("c"), s.targetIds)
        assertTrue(s.targets.isEmpty())
    }

    @Test
    fun `a new range clears everything built against the old one`() {
        val s = state(walk, run)
        s.toggleChecked("a")
        s.focus("b")
        s.toggleTargetVisibility()
        s.toggleType("running")
        s.setDistanceFilter(DistanceRange(0.0, 2000.0))
        s.startOver()
        assertTrue(s.checked.isEmpty() && s.hidden.isEmpty() && s.excludedTypes.isEmpty())
        assertNull(s.focused)
        assertNull(s.distanceFilter)
    }

    @Test
    fun `a refreshed list keeps what still exists`() {
        val s = state(walk, run)
        s.focus("b")
        s.setTracks(listOf(walk))
        assertNull(s.focused)
        s.setTracks(listOf(walk, run))
        s.toggleChecked("a")
        s.toggleChecked("b")
        s.setTracks(listOf(walk))
        assertEquals(setOf("a"), s.checked)
    }

    @Test
    fun `the first check starts selecting, bringing the selected one into the group`() {
        val s = state(walk, run)
        s.focus("a")
        assertTrue(s.toggleChecked("b"))
        assertTrue(s.selecting)
        assertNull(s.focused)
        assertEquals(setOf("a", "b"), s.checked)
        assertEquals(setOf("a", "b"), s.highlighted)
    }

    @Test
    fun `unchecking the last one ends selecting`() {
        val s = state(walk, run)
        s.toggleChecked("a")
        assertFalse(s.toggleChecked("a"))
        assertFalse(s.selecting)
        assertEquals(emptySet<String>(), s.highlighted)
    }

    @Test
    fun `selecting one track ends selecting`() {
        val s = state(walk, run)
        s.toggleChecked("a")
        s.focus("b")
        assertFalse(s.selecting)
        assertEquals(setOf("b"), s.highlighted)
    }

    @Test
    fun `a new range ends selecting`() {
        val s = state(walk)
        s.toggleChecked("a")
        s.startOver()
        assertFalse(s.selecting)
    }

    @Test
    fun `an empty list blames the filters only when one is set`() {
        assertFalse(PanelRules.emptyListFiltered(hasActiveFilters = false, datesSet = false))
        assertTrue(PanelRules.emptyListFiltered(hasActiveFilters = true, datesSet = false))
        assertTrue(PanelRules.emptyListFiltered(hasActiveFilters = false, datesSet = true))
    }
}
