package dev.holdmytrack.android.map

import dev.holdmytrack.android.R
import dev.holdmytrack.android.net.Explored
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class FogLevelsTest {

    private val levels = listOf(
        FogLevels.Level("country", below = 3.0, layers = listOf("countries-fill", "countries-line")),
        FogLevels.Level("county", from = 6.0, below = 8.0, layers = listOf("counties-fill")),
        FogLevels.Level("exact", from = 11.0, layers = listOf("fog")),
    )

    @Test
    fun `with nothing locked each level draws in its band`() {
        val ranges = FogLevels.zoomRanges(levels, null)
        assertEquals(0f..3f, ranges["countries-fill"])
        assertEquals(0f..3f, ranges["countries-line"])
        assertEquals(6f..8f, ranges["counties-fill"])
        assertEquals(11f..24f, ranges["fog"])
    }

    @Test
    fun `a locked level draws at every zoom and the others at none`() {
        val ranges = FogLevels.zoomRanges(levels, "county")
        assertEquals(0f..24f, ranges["counties-fill"])
        assertEquals(24f..24f, ranges["countries-fill"])
        assertEquals(24f..24f, ranges["fog"])
    }

    @Test
    fun `a lock on a level the document doesn't have follows the bands`() {
        assertEquals(FogLevels.zoomRanges(levels, null), FogLevels.zoomRanges(levels, "city"))
    }

    @Test
    fun `exact coverage counts no places`() {
        val explored = Explored(countries = 3, regions = 7, counties = 12, cities = 40)
        assertEquals(3, FogLevels.exploredCount(explored, "country"))
        assertEquals(40, FogLevels.exploredCount(explored, "city"))
        assertNull(FogLevels.exploredCount(explored, "exact"))
    }

    @Test
    fun `regions and counties take the country's word, other levels the generic name`() {
        assertEquals(R.string.fog_type_state, FogLevelMenu.levelLabel("region", "state"))
        assertEquals(R.string.fog_type_department, FogLevelMenu.levelLabel("county", "department"))
        assertEquals(R.string.fog_level_county, FogLevelMenu.levelLabel("county", "no_such_word"))
        assertEquals(R.string.fog_level_region, FogLevelMenu.levelLabel("region", null))
        assertEquals(R.string.fog_level_city, FogLevelMenu.levelLabel("city", "town"))
        assertEquals(R.string.fog_level_exact, FogLevelMenu.levelLabel("exact", null))
    }
}