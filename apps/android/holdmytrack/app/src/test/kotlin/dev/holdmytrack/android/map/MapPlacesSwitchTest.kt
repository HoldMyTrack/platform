package dev.holdmytrack.android.map

import org.junit.Assert.assertEquals
import org.junit.Test

class MapPlacesSwitchTest {
    @Test
    fun `before it was ever set, Show places takes Show layers' state`() {
        assertEquals(false, MapPlacesSwitch.initial(stored = null, layersOn = false))
        assertEquals(true, MapPlacesSwitch.initial(stored = null, layersOn = true))
    }

    @Test
    fun `once set, it stands on its own`() {
        assertEquals(true, MapPlacesSwitch.initial(stored = true, layersOn = false))
        assertEquals(false, MapPlacesSwitch.initial(stored = false, layersOn = true))
    }
}
