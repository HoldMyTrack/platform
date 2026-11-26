package dev.holdmytrack.android.panel

import org.junit.Assert.assertEquals
import org.junit.Test

/** The DISTANCE slider's positions: whole kilometers or miles, one a step. */
class TrackFiltersTest {
    @Test
    fun `a whole number of units is that many steps`() {
        assertEquals(12f, TrackFacets.sliderUnits(12000.0, imperial = false))
        assertEquals(10f, TrackFacets.sliderUnits(16093.44, imperial = true))
    }

    @Test
    fun `an end that isn't whole draws at the nearest step`() {
        assertEquals(3f, TrackFacets.sliderUnits(5000.0, imperial = true))
    }

    @Test
    fun `a step back in meters is the whole-unit end exactly`() {
        val ends = TrackFacets.wholeDistanceBounds(DistanceRange(1700.0, 16093.44), imperial = true)!!
        assertEquals(ends.max, TrackFacets.sliderMeters(TrackFacets.sliderUnits(ends.max, true), true), 0.0)
        assertEquals(ends.min, TrackFacets.sliderMeters(TrackFacets.sliderUnits(ends.min, true), true), 0.0)
    }
}
