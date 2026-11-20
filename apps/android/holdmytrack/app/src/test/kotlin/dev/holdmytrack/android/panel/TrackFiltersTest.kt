package dev.holdmytrack.android.panel

import org.junit.Assert.assertEquals
import org.junit.Test

class TrackFiltersTest {
    private val bounds = DistanceRange(1234.567, 98765.4321)

    @Test
    fun `a knob within a metre of an end lands on that end's track`() {
        assertEquals(bounds.min, TrackFilters.snap(bounds.min.toFloat(), bounds), 0.0)
        assertEquals(bounds.max, TrackFilters.snap(bounds.max.toFloat(), bounds), 0.0)
        assertEquals(bounds.min, TrackFilters.snap(1235.0f, bounds), 0.0)
    }

    @Test
    fun `a knob between the ends stays where it is`() {
        assertEquals(50000.0, TrackFilters.snap(50000f, bounds), 0.0)
        assertEquals(1236.0, TrackFilters.snap(1236f, bounds), 0.0)
    }
}
