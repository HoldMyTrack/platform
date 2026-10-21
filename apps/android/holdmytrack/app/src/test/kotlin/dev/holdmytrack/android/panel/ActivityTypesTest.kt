package dev.holdmytrack.android.panel

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** What the app shows for an activity type: the server's, else its fallback. */
class ActivityTypesTest {

    @Test
    fun `a type the server described shows as it said`() {
        ActivityTypes.merge(mapOf("gravel_cycling_test" to ActivityTypes.Info(ActivityKind.WHEELS, "Gravel Cycling")))
        assertEquals("Gravel Cycling", ActivityTypes.label("gravel_cycling_test"))
        assertEquals(ActivityKind.WHEELS, ActivityTypes.kind("gravel_cycling_test"))
    }

    @Test
    fun `a Story's label leaves a known kind as it was`() {
        ActivityTypes.merge(mapOf("evening_ride_test" to ActivityTypes.Info(ActivityKind.WHEELS, "Evening Ride")))
        ActivityTypes.merge(mapOf("evening_ride_test" to ActivityTypes.Info(null, "Вечерняя поездка")))
        assertEquals(ActivityKind.WHEELS, ActivityTypes.kind("evening_ride_test"))
        assertEquals("Вечерняя поездка", ActivityTypes.label("evening_ride_test"))
    }

    @Test
    fun `a type not described yet falls back as the server does`() {
        assertEquals("Never Described Here", ActivityTypes.label("never_described_here"))
        assertEquals("X", ActivityTypes.fallbackLabel("__x__"))
        assertEquals(ActivityKind.OTHER, ActivityTypes.kind("never_described_here"))
    }

    @Test
    fun `a change is heard, an unchanged merge isn't`() {
        var heard = 0
        val listener: () -> Unit = { heard++ }
        ActivityTypes.addListener(listener)
        ActivityTypes.merge(mapOf("listened_test" to ActivityTypes.Info(ActivityKind.FOOT, "Listened")))
        ActivityTypes.merge(mapOf("listened_test" to ActivityTypes.Info(ActivityKind.FOOT, "Listened")))
        assertTrue(heard == 1)
    }
}
