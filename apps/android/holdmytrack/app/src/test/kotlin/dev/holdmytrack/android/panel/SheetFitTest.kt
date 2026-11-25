package dev.holdmytrack.android.panel

import org.junit.Assert.assertEquals
import org.junit.Test

class SheetFitTest {
    private fun resting(top: Int) = SheetFit.bottomPadding(top = top, expandedTop = 136, halfTop = 1000, current = 42, moving = false)

    @Test
    fun openTheContentReachesTheSheetsBottom() = assertEquals(0, resting(top = 136))

    @Test
    fun halfwayTheContentEndsAtTheScreensBottom() = assertEquals(864, resting(top = 1000))

    @Test
    fun belowHalfwayItKeepsTheHalfsPadding() = assertEquals(864, resting(top = 1700))

    @Test
    fun neverNegative() = assertEquals(0, resting(top = 100))

    @Test
    fun movingItKeepsThePaddingItHas() =
        assertEquals(864, SheetFit.bottomPadding(top = 600, expandedTop = 136, halfTop = 1000, current = 864, moving = true))
}
