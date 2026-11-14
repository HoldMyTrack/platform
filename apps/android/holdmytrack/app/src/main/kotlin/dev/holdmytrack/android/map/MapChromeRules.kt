package dev.holdmytrack.android.map

import dev.holdmytrack.android.panel.PanelTab

/** The map's notices, most important first: when two apply, the earlier stays up. */
enum class MapNotice { MAP_FAILED, UNREACHABLE, BASEMAP_UNREACHABLE, SATELLITE_FAILED, CHECKING, EMPTY, CAPPED }

/**
 * Which of the map's controls and notices show, as plain values `MapFragment` renders.
 * `sessionReady` is the session confirmed and the mode toggle shown once (`syncSession`).
 */
object MapChromeRules {
    /** Normal mode, session ready, not recording: when the sheet and its editors have the map. */
    fun normalMode(sessionReady: Boolean, mode: MapMode, recording: Boolean): Boolean =
        sessionReady && mode == MapMode.NORMAL && !recording

    /** The mode toggle: the Map tab's, hidden while recording, editing or checking rows. */
    fun modeBarShown(recording: Boolean, editOpen: Boolean, selectionShown: Boolean, tab: PanelTab): Boolean =
        tab == PanelTab.ACTIVITIES && !recording && !editOpen && !selectionShown

    /** The mode the map shows: the one picked on the Map tab there, Normal on Stories and Sync,
     *  whose sheet and tracks are Normal mode's; back on Map, the pick comes back. */
    fun tabMode(picked: MapMode, tab: PanelTab): MapMode = if (tab == PanelTab.ACTIVITIES) picked else MapMode.NORMAL

    /** The mode carried through a recreation, by name; Normal for none or one this build lacks. */
    fun restoredMode(saved: String?): MapMode = MapMode.entries.firstOrNull { it.name == saved } ?: MapMode.NORMAL

    /** "Your map is still being updated…" (`docs/SPEC.md` FR-4.2), in Fog while coverage
     *  is rendering. */
    fun coverageNoticeShown(rendering: Boolean, mode: MapMode, sessionReady: Boolean, recording: Boolean): Boolean =
        rendering && mode != MapMode.NORMAL && sessionReady && !recording

    /** The rail (Layers, Find my location), hidden while an editor is open or rows are checked. */
    fun railShown(editing: Boolean, selectionShown: Boolean): Boolean = !editing && !selectionShown

    /** The bottom bar and the record button over it, gone while the Edit window, the Private
     *  location editor or the image export has the screen: a tab or a recording would start
     *  under it. */
    fun bottomBarShown(editOpen: Boolean, privacyEditing: Boolean, exportOpen: Boolean): Boolean =
        !editOpen && !privacyEditing && !exportOpen

    /** The image export's own button under the selection bar, while rows are checked and the rail
     *  is away, so an image can show the Checked activities' stats (`docs/SPEC.md` FR-4.10). */
    fun checkedExportShown(editing: Boolean, selectionShown: Boolean): Boolean = !editing && selectionShown

    /** Whether rows are being checked where the selection bar can show: the sheet up on the
     *  Activities tab, no Edit window. */
    fun selectionShown(sheetVisible: Boolean, selecting: Boolean, tab: PanelTab, editOpen: Boolean): Boolean =
        sheetVisible && selecting && tab == PanelTab.ACTIVITIES && !editOpen

    /** The list's summary at the sheet's head: the Activities tab's, in Normal mode, unless the
     *  selected activity's card has the head. */
    fun summaryShown(normal: Boolean, tab: PanelTab, showsCard: Boolean): Boolean =
        normal && tab == PanelTab.ACTIVITIES && !showsCard

    /** The sheet: Normal mode's, and the Sync tab's even while recording, so what's on the phone
     *  can be sent mid-walk; hidden while an editor has the screen. */
    fun sheetShown(normal: Boolean, sessionReady: Boolean, mode: MapMode, tab: PanelTab, editing: Boolean): Boolean {
        val syncing = sessionReady && mode == MapMode.NORMAL && tab == PanelTab.SYNC
        return (normal || syncing) && !editing
    }

    /** Whether [next] may replace the notice up: a less important one never replaces a more important one. */
    fun noticeReplaces(current: MapNotice?, next: MapNotice): Boolean = current == null || current.ordinal >= next.ordinal

    /** The empty and capped notices step aside while recording and on the Sync tab, whose lists
     *  aren't the area's; failures stay up. */
    fun noticeShown(kind: MapNotice?, recording: Boolean, onSync: Boolean): Boolean =
        kind != null && !((kind == MapNotice.EMPTY || kind == MapNotice.CAPPED) && (recording || onSync))
}
