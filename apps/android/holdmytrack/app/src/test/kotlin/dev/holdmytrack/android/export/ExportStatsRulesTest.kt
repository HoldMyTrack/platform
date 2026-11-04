package dev.holdmytrack.android.export

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ExportStatsRulesTest {

    @Test
    fun theCardIsAskedForOnlyWithShowStatsTickedAndOffered() {
        assertNull(ExportStatsRules.request(false, setOf("a"), null, 1920, 1080, false))
        assertNull(ExportStatsRules.request(true, emptySet(), null, 1920, 1080, false))
        assertNull(ExportStatsRules.request(true, setOf("a"), "story", 1920, 1080, false))
    }

    @Test
    fun theRequestCarriesTheImageSizeAndThemeItsIdsSorted() {
        assertEquals(
            ExportStatsRules.Request(listOf("a", "b"), 1920, 1080, dark = true),
            ExportStatsRules.request(true, setOf("b", "a"), null, 1920, 1080, true),
        )
    }

    @Test
    fun theSameCheckedSetSizeAndThemeIsTheSameKey() {
        fun key(checked: Set<String>, w: Int = 1920, dark: Boolean = false) =
            ExportStatsRules.request(true, checked, null, w, 1080, dark)!!.key
        assertEquals(key(setOf("a", "b")), key(setOf("b", "a")))
        assertNotEquals(key(setOf("a")), key(setOf("a", "b")))
        assertNotEquals(key(setOf("a")), key(setOf("a"), w = 1080))
        assertNotEquals(key(setOf("a")), key(setOf("a"), dark = true))
    }
}
