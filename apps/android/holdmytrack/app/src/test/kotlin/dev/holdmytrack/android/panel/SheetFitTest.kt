package dev.holdmytrack.android.panel

import org.junit.Assert.assertEquals
import org.junit.Test

class SheetFitTest {
    private fun fit(top: Int, moving: Boolean = false, resized: Boolean = false) =
        SheetFit.bottomPadding(top = top, expandedTop = 136, halfTop = 1000, current = 864, moving = moving, resized = resized)

    @Test
    fun openTheContentReachesTheSheetsBottom() = assertEquals(0, fit(top = 136))

    @Test
    fun halfwayTheContentEndsAtTheScreensBottom() = assertEquals(864, fit(top = 1000))

    /** A rotation lays the resting sheet out at its old top before it moves to its state's. */
    @Test
    fun atRestBetweenOpenAndHalfwayItFollowsTheTop() = assertEquals(464, fit(top = 600))

    @Test
    fun belowHalfwayItKeepsTheHalfsPadding() = assertEquals(864, fit(top = 1700))

    @Test
    fun neverNegative() = assertEquals(0, fit(top = 100))

    @Test
    fun movingItKeepsThePaddingItHas() = assertEquals(864, fit(top = 600, moving = true))

    @Test
    fun resizedMidSlideItFitsTheNewWindow() = assertEquals(464, fit(top = 600, moving = true, resized = true))
}
