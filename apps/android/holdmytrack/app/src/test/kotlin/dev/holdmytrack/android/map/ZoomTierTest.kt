package dev.holdmytrack.android.map

import dev.holdmytrack.android.R
import org.junit.Assert.assertEquals
import org.junit.Test

class ZoomTierTest {

    @Test
    fun fogNamesTheTier() {
        assertEquals(R.string.map_level_fog_country, levelNoticeText(ZoomTier.COUNTRY))
        assertEquals(R.string.map_level_fog_region, levelNoticeText(ZoomTier.REGION))
        assertEquals(R.string.map_level_fog_city, levelNoticeText(ZoomTier.CITY))
    }
}
