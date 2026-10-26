package dev.holdmytrack.android.tour

import dev.holdmytrack.android.MainActivity
import dev.holdmytrack.android.map.MapMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TourStepsTest {

    @Test
    fun `a demo's Fog is city, states and countries at Fog's zoom tiers`() {
        val fog = TourSteps.of(isDemo = true).filter { it.mode == MapMode.FOG }
        assertEquals(listOf("fog", "fog_regions", "fog_countries"), fog.map { it.id })
        // Exact coverage from zoom 7, regions 3–6, countries 0–2 (docs/SPEC.md FR-4.2).
        assertTrue(fog[0].view!!.zoom >= 7)
        assertTrue(fog[1].view!!.zoom >= 3 && fog[1].view!!.zoom < 7)
        assertTrue(fog[2].view!!.zoom < 3)
        assertEquals(listOf("fog"), TourSteps.of(isDemo = true).filter { it.card == TourCard.FOG }.map { it.id })
    }

    @Test
    fun `only the demo moves the camera on its own views`() {
        assertTrue(TourSteps.of(isDemo = false).all { it.view == null })
        assertEquals(TourSteps.HEATMAP_CITY, TourSteps.of(isDemo = true).single { it.id == "heatmap" }.view)
    }

    @Test
    fun `the pan goes east in legs under 180 degrees`() {
        val points = listOf(TourSteps.COUNTRIES.lon) + TourSteps.COUNTRIES.pan.map { it.first }
        points.zipWithNext().forEach { (a, b) -> assertTrue("$a to $b", b - a in 0.0..180.0) }
    }

    @Test
    fun `the Normal steps come before Fog and Heatmap, which come together`() {
        val modes = TourSteps.of(isDemo = true).map { it.mode }
        val first = modes.indexOfFirst { it != MapMode.NORMAL }
        val last = modes.indexOfLast { it != MapMode.NORMAL }
        assertTrue(modes.subList(first, last + 1).none { it == MapMode.NORMAL })
    }

    @Test
    fun `steps open what they explain and end on the You tab`() {
        val steps = TourSteps.of(isDemo = false).associateBy { it.id }
        assertEquals(MainActivity.Tab.STORIES, steps.getValue("stories").tab)
        assertTrue(steps.getValue("stories").sheet && steps.getValue("activities").sheet)
        assertTrue(steps.getValue("layers").layers)
        assertEquals(MainActivity.Tab.SYNC, steps.getValue("sync").tab)
        assertEquals(MainActivity.Tab.YOU, TourSteps.of(isDemo = false).last().tab)
        assertEquals("tour_sync_demo", TourSteps.of(isDemo = true).single { it.id == "sync" }.text)
        assertTrue(TourSteps.movesCamera(steps.getValue("stories")))
        assertFalse(TourSteps.movesCamera(steps.getValue("layers")))
    }

    @Test
    fun `the card goes on top only when it fits above the target`() {
        // The panel's strip at the foot of the screen.
        assertEquals(TourSteps.Edge.TOP, TourSteps.edge(targetTop = 1800, cardHeight = 500, topInset = 100, gap = 40))
        // The open sheet, or the mode bar at the top.
        assertEquals(TourSteps.Edge.BOTTOM, TourSteps.edge(targetTop = 400, cardHeight = 500, topInset = 100, gap = 40))
        assertEquals(TourSteps.Edge.BOTTOM, TourSteps.edge(targetTop = null, cardHeight = 500, topInset = 100, gap = 40))
        assertNull(TourSteps.of(isDemo = false).first().target)
    }
}