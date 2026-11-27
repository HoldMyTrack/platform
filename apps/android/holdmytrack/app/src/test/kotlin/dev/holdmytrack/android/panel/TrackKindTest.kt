package dev.holdmytrack.android.panel

import org.junit.Assert.assertEquals
import org.junit.Test

class TrackKindTest {

    @Test
    fun kindsAreTheServersWireNames() {
        assertEquals(TrackKind.FOOT, TrackKind.fromWire("foot"))
        assertEquals(TrackKind.SOLOWHEEL, TrackKind.fromWire("solowheel"))
        assertEquals(TrackKind.E_SCOOTER, TrackKind.fromWire("e_scooter"))
        assertEquals(TrackKind.OTHER, TrackKind.fromWire("hovercraft"))
    }
}
