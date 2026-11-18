package dev.holdmytrack.android.tour

import dev.holdmytrack.android.MainActivity
import dev.holdmytrack.android.map.MapMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TourStepsTest {

    @Test
    fun `a demo's Fog is a step per level, each in its level's band`() {
        val fog = TourSteps.of(isDemo = true).filter { it.mode == MapMode.FOG }
        assertEquals(listOf("fog", "fog_cities", "fog_counties", "fog_regions", "fog_countries"), fog.map { it.id })
        // Exact from zoom 11, cities 8–11, counties 6–8, regions 3–6, countries 0–3 (docs/SPEC.md FR-4.2).
        val bands = listOf(11.0 to 24.0, 8.0 to 11.0, 6.0 to 8.0, 3.0 to 6.0, 0.0 to 3.0)
        fog.zip(bands).forEach { (step, band) -> assertTrue(step.id, step.view!!.zoom >= band.first && step.view!!.zoom < band.second) }
        assertEquals(listOf("fog"), TourSteps.of(isDemo = true).filter { it.card == TourCard.FOG }.map { it.id })
    }

    @Test
    fun `only the demo moves the camera on its own views`() {
        assertTrue(TourSteps.of(isDemo = false).all { it.view == null })
        assertTrue(TourSteps.of(isDemo = true).any { it.view != null })
    }

    @Test
    fun `the pan goes east in legs under 180 degrees`() {
        val points = listOf(TourSteps.COUNTRIES.lon) + TourSteps.COUNTRIES.pan.map { it.first }
        points.zipWithNext().forEach { (a, b) -> assertTrue("$a to $b", b - a in 0.0..180.0) }
    }

    @Test
    fun `the Fog steps come together`() {
        val modes = TourSteps.of(isDemo = true).map { it.mode }
        val first = modes.indexOfFirst { it != MapMode.NORMAL }
        val last = modes.indexOfLast { it != MapMode.NORMAL }
        assertTrue(modes.subList(first, last + 1).none { it == MapMode.NORMAL })
    }

    @Test
    fun `steps open what they explain and end on the You tab`() {
        val steps = TourSteps.of(isDemo = false).associateBy { it.id }
        assertEquals(MainActivity.Tab.TRIPS, steps.getValue("trips").tab)
        assertTrue(steps.getValue("trips").sheet && steps.getValue("tracks").sheet)
        assertTrue(steps.getValue("layers").layers && !steps.getValue("layers").places)
        assertTrue(steps.getValue("places").places && !steps.getValue("places").layers)
        assertEquals(TourTarget.PLACES, steps.getValue("places").target)
        assertEquals(MainActivity.Tab.SYNC, steps.getValue("sync").tab)
        assertEquals(MainActivity.Tab.YOU, TourSteps.of(isDemo = false).last().tab)
        assertEquals("tour_sync_demo", TourSteps.of(isDemo = true).single { it.id == "sync" }.text)
    }

    @Test
    fun `every step and card has its text`() {
        val keys = (TourSteps.of(isDemo = true) + TourSteps.of(isDemo = false)).map { it.text } + TourCard.entries.map { TourSteps.card(it).first }
        val missing = keys.toSet() - TourText.ALL.keys
        assertTrue("no text for $missing", missing.isEmpty())
    }

    @Test
    fun `a step holds the sheet and the menus it says, and the end gives the sheet back`() {
        val steps = TourSteps.of(isDemo = false).associateBy { it.id }
        assertEquals(TourSteps.Held(sheet = true), TourSteps.held(steps.getValue("tracks"), restoreSheet = false))
        assertEquals(TourSteps.Held(sheet = false, layers = true), TourSteps.held(steps.getValue("layers"), restoreSheet = true))
        assertEquals(TourSteps.Held(sheet = false, places = true), TourSteps.held(steps.getValue("places"), restoreSheet = true))
        assertEquals(TourSteps.Held(sheet = true), TourSteps.held(null, restoreSheet = true))
        assertEquals(TourSteps.Held(sheet = false), TourSteps.held(null, restoreSheet = false))
    }

    @Test
    fun `Fog's level menu opens after the mode change, every other menu before it`() {
        val fog = TourSteps.menuMoves(TourSteps.Held(sheet = false, fogLevel = true))
        assertEquals(listOf(TourMenu.FOG_LEVEL to true), fog.after)
        assertEquals(listOf(TourMenu.LAYERS to false, TourMenu.PLACES to false), fog.before)
        val places = TourSteps.menuMoves(TourSteps.Held(sheet = false, places = true))
        assertEquals(listOf(TourMenu.LAYERS to false, TourMenu.PLACES to true, TourMenu.FOG_LEVEL to false), places.before)
        assertEquals(emptyList<Pair<TourMenu, Boolean>>(), places.after)
    }

    @Test
    fun `Fog's level menu opens on the last Fog step only`() {
        assertEquals(listOf("fog"), TourSteps.of(isDemo = false).filter { it.fogLevel }.map { it.id })
        assertEquals(listOf("fog_countries"), TourSteps.of(isDemo = true).filter { it.fogLevel }.map { it.id })
        assertEquals(TourSteps.Held(sheet = false, fogLevel = true), TourSteps.held(TourSteps.of(isDemo = true).single { it.id == "fog_countries" }, restoreSheet = true))
    }

    @Test
    fun `a first-time card goes under a target in the upper half, else over it, never above the inset`() {
        // The mode bar near the top.
        assertEquals(330, TourSteps.cardTop(targetTop = 180, targetBottom = 300, cardHeight = 500, height = 2000, topInset = 100, gap = 30))
        // The sheet near the bottom.
        assertEquals(1270, TourSteps.cardTop(targetTop = 1800, targetBottom = 1900, cardHeight = 500, height = 2000, topInset = 100, gap = 30))
        // Over a low target with no room above: held at the inset.
        assertEquals(100, TourSteps.cardTop(targetTop = 1100, targetBottom = 1900, cardHeight = 1500, height = 2000, topInset = 100, gap = 30))
        assertEquals(100, TourSteps.cardTop(targetTop = null, targetBottom = null, cardHeight = 500, height = 2000, topInset = 100, gap = 30))
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