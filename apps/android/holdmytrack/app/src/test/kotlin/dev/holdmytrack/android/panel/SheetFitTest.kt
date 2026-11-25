package dev.holdmytrack.android.panel

import org.junit.Assert.assertEquals
import org.junit.Test

class SheetFitTest {
    @Test
    fun openTheContentReachesTheSheetsBottom() = assertEquals(0, SheetFit.bottomPadding(top = 136, expandedTop = 136, halfTop = 1000))

    @Test
    fun halfwayTheContentEndsAtTheScreensBottom() = assertEquals(864, SheetFit.bottomPadding(top = 1000, expandedTop = 136, halfTop = 1000))

    @Test
    fun midDragItFollowsTheTop() = assertEquals(464, SheetFit.bottomPadding(top = 600, expandedTop = 136, halfTop = 1000))

    @Test
    fun belowHalfwayItKeepsTheHalfsPadding() = assertEquals(864, SheetFit.bottomPadding(top = 1700, expandedTop = 136, halfTop = 1000))

    @Test
    fun neverNegative() = assertEquals(0, SheetFit.bottomPadding(top = 100, expandedTop = 136, halfTop = 1000))
}
