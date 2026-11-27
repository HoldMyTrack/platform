package dev.holdmytrack.android.panel

import dev.holdmytrack.android.panel.SheetRules.Detent
import org.junit.Assert.assertEquals
import org.junit.Test

class SheetRulesTest {
    @Test
    fun aRowTapBringsAnOpenSheetDownToHalf() = assertEquals(Detent.HALF, SheetRules.afterRowTap(Detent.EXPANDED))

    @Test
    fun aRowTapLeavesAHalfOrCollapsedSheetWhereItIs() {
        assertEquals(Detent.HALF, SheetRules.afterRowTap(Detent.HALF))
        assertEquals(Detent.COLLAPSED, SheetRules.afterRowTap(Detent.COLLAPSED))
    }
}
