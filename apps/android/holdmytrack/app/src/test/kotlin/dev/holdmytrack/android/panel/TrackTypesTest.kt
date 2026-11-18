package dev.holdmytrack.android.panel

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** What the app shows for a track type: the server's, else its fallback. */
class TrackTypesTest {

    @Test
    fun `a type the server described shows as it said`() {
        TrackTypes.merge(mapOf("gravel_cycling_test" to TrackTypes.Info(TrackKind.WHEELS, "Gravel Cycling")))
        assertEquals("Gravel Cycling", TrackTypes.label("gravel_cycling_test"))
        assertEquals(TrackKind.WHEELS, TrackTypes.kind("gravel_cycling_test"))
    }

    @Test
    fun `a Trip's label leaves a known kind as it was`() {
        TrackTypes.merge(mapOf("evening_ride_test" to TrackTypes.Info(TrackKind.WHEELS, "Evening Ride")))
        TrackTypes.merge(mapOf("evening_ride_test" to TrackTypes.Info(null, "Вечерняя поездка")))
        assertEquals(TrackKind.WHEELS, TrackTypes.kind("evening_ride_test"))
        assertEquals("Вечерняя поездка", TrackTypes.label("evening_ride_test"))
    }

    @Test
    fun `a type not described yet falls back as the server does`() {
        assertEquals("Never Described Here", TrackTypes.label("never_described_here"))
        assertEquals("X", TrackTypes.fallbackLabel("__x__"))
        assertEquals(TrackKind.OTHER, TrackTypes.kind("never_described_here"))
    }

    @Test
    fun `a change is heard, an unchanged merge isn't`() {
        var heard = 0
        val listener: () -> Unit = { heard++ }
        TrackTypes.addListener(listener)
        TrackTypes.merge(mapOf("listened_test" to TrackTypes.Info(TrackKind.FOOT, "Listened")))
        TrackTypes.merge(mapOf("listened_test" to TrackTypes.Info(TrackKind.FOOT, "Listened")))
        assertTrue(heard == 1)
    }
}
