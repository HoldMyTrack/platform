package dev.holdmytrack.android.panel

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PickerSheetTest {
    private val rows = listOf(PickerSheet.Item("cycling", "Cycling"), PickerSheet.Item("biking", "Biking"))

    @Test
    fun `Done picks the top row once something is typed`() {
        assertEquals("cycling", PickerSheet.doneValue("cy", rows))
    }

    @Test
    fun `Done with nothing typed picks nothing`() {
        assertNull(PickerSheet.doneValue("", rows))
        assertNull(PickerSheet.doneValue("  ", rows))
    }

    @Test
    fun `Done with no row left picks nothing`() {
        assertNull(PickerSheet.doneValue("zz", emptyList()))
    }

    @Test
    fun `Done skips a row that can't be picked`() {
        val rows = listOf(PickerSheet.Item("a", "Alps", enabled = false), PickerSheet.Item("b", "Alpine lakes"))
        assertEquals("b", PickerSheet.doneValue("alp", rows))
    }
}
