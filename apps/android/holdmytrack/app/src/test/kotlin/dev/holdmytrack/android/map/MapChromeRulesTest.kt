package dev.holdmytrack.android.map

import dev.holdmytrack.android.panel.PanelTab
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MapChromeRulesTest {

    @Test
    fun `Normal mode needs the session and no recording`() {
        assertTrue(MapChromeRules.normalMode(sessionReady = true, MapMode.NORMAL, recording = false))
        assertFalse(MapChromeRules.normalMode(sessionReady = false, MapMode.NORMAL, recording = false))
        assertFalse(MapChromeRules.normalMode(sessionReady = true, MapMode.FOG, recording = false))
        assertFalse(MapChromeRules.normalMode(sessionReady = true, MapMode.NORMAL, recording = true))
    }

    @Test
    fun `the mode chip names Fog and Heatmap only, and steps aside for recording and export`() {
        assertFalse(MapChromeRules.modeChipShown(MapMode.NORMAL, sessionReady = true, recording = false, exportOpen = false))
        assertTrue(MapChromeRules.modeChipShown(MapMode.HEATMAP, sessionReady = true, recording = false, exportOpen = false))
        assertFalse(MapChromeRules.modeChipShown(MapMode.FOG, sessionReady = true, recording = true, exportOpen = false))
        assertFalse(MapChromeRules.modeChipShown(MapMode.FOG, sessionReady = true, recording = false, exportOpen = true))
    }

    @Test
    fun `the coverage notice shows in Fog and Heatmap while rendering`() {
        assertTrue(MapChromeRules.coverageNoticeShown(rendering = true, MapMode.FOG, sessionReady = true, recording = false))
        assertFalse(MapChromeRules.coverageNoticeShown(rendering = true, MapMode.NORMAL, sessionReady = true, recording = false))
        assertFalse(MapChromeRules.coverageNoticeShown(rendering = false, MapMode.FOG, sessionReady = true, recording = false))
    }

    @Test
    fun `the bottom bar steps aside for the editors and the image export`() {
        assertTrue(MapChromeRules.bottomBarShown(editOpen = false, privacyEditing = false, exportOpen = false))
        assertFalse(MapChromeRules.bottomBarShown(editOpen = true, privacyEditing = false, exportOpen = false))
        assertFalse(MapChromeRules.bottomBarShown(editOpen = false, privacyEditing = true, exportOpen = false))
        assertFalse(MapChromeRules.bottomBarShown(editOpen = false, privacyEditing = false, exportOpen = true))
    }

    @Test
    fun `Stories and Sync show Normal with no toggle, and the Map tab gets its pick back`() {
        for (tab in listOf(PanelTab.STORIES, PanelTab.SYNC)) {
            assertEquals(MapMode.NORMAL, MapChromeRules.tabMode(MapMode.HEATMAP, tab))
            assertFalse(MapChromeRules.modeBarShown(recording = false, editOpen = false, selectionShown = false, tab))
        }
        assertEquals(MapMode.HEATMAP, MapChromeRules.tabMode(MapMode.HEATMAP, PanelTab.ACTIVITIES))
        assertTrue(MapChromeRules.modeBarShown(recording = false, editOpen = false, selectionShown = false, PanelTab.ACTIVITIES))
    }

    @Test
    fun `checking rows hides the mode toggle and the rail`() {
        assertTrue(MapChromeRules.selectionShown(sheetVisible = true, selecting = true, PanelTab.ACTIVITIES, editOpen = false))
        assertFalse(MapChromeRules.selectionShown(sheetVisible = true, selecting = true, PanelTab.STORIES, editOpen = false))
        assertFalse(MapChromeRules.modeBarShown(recording = false, editOpen = false, selectionShown = true, PanelTab.ACTIVITIES))
        assertFalse(MapChromeRules.railShown(editing = false, selectionShown = true))
        assertTrue(MapChromeRules.railShown(editing = false, selectionShown = false))
    }

    @Test
    fun `checking rows keeps the image export at hand, without the rail`() {
        assertTrue(MapChromeRules.checkedExportShown(editing = false, selectionShown = true))
        assertFalse(MapChromeRules.checkedExportShown(editing = false, selectionShown = false))
        assertFalse(MapChromeRules.checkedExportShown(editing = true, selectionShown = true))
    }

    @Test
    fun `the Sync tab keeps the sheet while recording, an editor hides it`() {
        assertTrue(MapChromeRules.sheetShown(normal = false, sessionReady = true, MapMode.NORMAL, PanelTab.SYNC, editing = false))
        assertFalse(MapChromeRules.sheetShown(normal = false, sessionReady = true, MapMode.NORMAL, PanelTab.ACTIVITIES, editing = false))
        assertFalse(MapChromeRules.sheetShown(normal = true, sessionReady = true, MapMode.NORMAL, PanelTab.ACTIVITIES, editing = true))
    }

    @Test
    fun `the summary is the Activities tab's head unless the card has it`() {
        assertTrue(MapChromeRules.summaryShown(normal = true, PanelTab.ACTIVITIES, showsCard = false))
        assertFalse(MapChromeRules.summaryShown(normal = true, PanelTab.ACTIVITIES, showsCard = true))
        assertFalse(MapChromeRules.summaryShown(normal = true, PanelTab.STORIES, showsCard = false))
        assertFalse(MapChromeRules.summaryShown(normal = false, PanelTab.ACTIVITIES, showsCard = false))
    }

    @Test
    fun `the capped notice steps aside where the list isn't the area's`() {
        assertTrue(MapChromeRules.noticeShown(MapNotice.CAPPED, recording = false, onSync = false))
        assertFalse(MapChromeRules.noticeShown(MapNotice.CAPPED, recording = true, onSync = false))
        assertFalse(MapChromeRules.noticeShown(MapNotice.CAPPED, recording = false, onSync = true))
    }

    @Test
    fun `a less important notice never replaces a more important one`() {
        assertTrue(MapChromeRules.noticeReplaces(null, MapNotice.EMPTY))
        assertTrue(MapChromeRules.noticeReplaces(MapNotice.EMPTY, MapNotice.MAP_FAILED))
        assertTrue(MapChromeRules.noticeReplaces(MapNotice.CHECKING, MapNotice.CHECKING))
        assertFalse(MapChromeRules.noticeReplaces(MapNotice.UNREACHABLE, MapNotice.EMPTY))
        assertTrue(MapChromeRules.noticeReplaces(MapNotice.EMPTY, MapNotice.BASEMAP_UNREACHABLE))
        assertFalse(MapChromeRules.noticeReplaces(MapNotice.MAP_FAILED, MapNotice.BASEMAP_UNREACHABLE))
    }

    @Test
    fun `the empty notice steps aside while recording and on Sync, failures stay`() {
        assertFalse(MapChromeRules.noticeShown(MapNotice.EMPTY, recording = true, onSync = false))
        assertFalse(MapChromeRules.noticeShown(MapNotice.EMPTY, recording = false, onSync = true))
        assertTrue(MapChromeRules.noticeShown(MapNotice.MAP_FAILED, recording = true, onSync = true))
        assertFalse(MapChromeRules.noticeShown(null, recording = false, onSync = false))
    }
}
