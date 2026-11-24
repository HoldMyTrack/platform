package dev.holdmytrack.android.panel

import org.junit.Assert.assertEquals
import org.junit.Test

class LibrarySliderTest {

    private val bounds = DistanceRange(0.0, 40_000.0)

    @Test
    fun `a filter inside the bounds is its own knobs, open-ended up to the top`() {
        assertEquals(DistanceRange(5_000.0, 20_000.0), LibraryTab.sliderRange(LibraryRules.Distance(5_000.0, 20_000.0), bounds))
        assertEquals(DistanceRange(5_000.0, 40_000.0), LibraryTab.sliderRange(LibraryRules.Distance(5_000.0, null), bounds))
    }

    @Test
    fun `a filter the bounds shrank under keeps both knobs inside them`() {
        // 50-80 km, then the tracks over 40 km deleted.
        assertEquals(DistanceRange(40_000.0, 40_000.0), LibraryTab.sliderRange(LibraryRules.Distance(50_000.0, 80_000.0), bounds))
        assertEquals(DistanceRange(10_000.0, 10_000.0), LibraryTab.sliderRange(LibraryRules.Distance(5_000.0, 8_000.0), DistanceRange(10_000.0, 40_000.0)))
    }
}
