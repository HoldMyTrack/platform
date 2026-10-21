package dev.holdmytrack.android.panel

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ActivityKindTest {

    @Test
    fun kindsAreTheServersWireNames() {
        assertEquals(ActivityKind.FOOT, ActivityKind.fromWire("foot"))
        assertEquals(ActivityKind.SOLOWHEEL, ActivityKind.fromWire("solowheel"))
        assertEquals(ActivityKind.E_SCOOTER, ActivityKind.fromWire("e_scooter"))
        assertEquals(ActivityKind.OTHER, ActivityKind.fromWire("hovercraft"))
    }

    @Test
    fun onlyFootShowsPace() {
        assertTrue(ActivityKind.FOOT.showsPace)
        assertEquals(ActivityKind.entries - ActivityKind.FOOT, ActivityKind.entries.filterNot { it.showsPace })
    }

    @Test
    fun paceIsMinutesAndSecondsPerUnit() {
        val perKm = Pace.secondsPerUnit(14_300.0, 78 * 60L, 1000.0)!!
        assertEquals("5:27", Pace.format(perKm))
        assertEquals("10:00", Pace.format(600.0))
    }

    @Test
    fun speedIsUnitsPerHour() {
        assertEquals(17.1, Pace.speed(24_800.0, 87 * 60L, 1000.0)!!, 0.05)
    }

    @Test
    fun noDistanceOrTimeHasNoPaceOrSpeed() {
        assertNull(Pace.secondsPerUnit(null, 60, 1000.0))
        assertNull(Pace.secondsPerUnit(1000.0, 0, 1000.0))
        assertNull(Pace.speed(0.0, 60, 1000.0))
    }
}
