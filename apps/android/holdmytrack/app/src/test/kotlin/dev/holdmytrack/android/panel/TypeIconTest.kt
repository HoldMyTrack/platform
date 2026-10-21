package dev.holdmytrack.android.panel

import dev.holdmytrack.android.R
import org.junit.Assert.assertEquals
import org.junit.Test

class TypeIconTest {

    @Test
    fun `each kind has its icon`() {
        assertEquals(R.drawable.ic_footprints, kindIcon(ActivityKind.FOOT))
        assertEquals(R.drawable.ic_bike, kindIcon(ActivityKind.WHEELS))
        assertEquals(R.drawable.ic_car, kindIcon(ActivityKind.MOTOR))
        assertEquals(R.drawable.ic_monowheel, kindIcon(ActivityKind.SOLOWHEEL))
        assertEquals(R.drawable.ic_electric_scooter, kindIcon(ActivityKind.E_SCOOTER))
        assertEquals(R.drawable.ic_route, kindIcon(ActivityKind.OTHER))
    }

    @Test
    fun `a type the server hasn't described takes the other kind's icon`() {
        assertEquals(R.drawable.ic_route, typeIcon("never_described_here"))
    }
}
