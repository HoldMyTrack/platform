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

    /** The mode toggle: the Tracks tab's, hidden while recording, editing or checking rows. */
    fun modeBarShown(recording: Boolean, editOpen: Boolean, selectionShown: Boolean, tab: PanelTab): Boolean =
        tab == PanelTab.TRACKS && !recording && !editOpen && !selectionShown

    /** The mode the map shows: the one picked on the Tracks tab there, Normal on Trips and Sync,
     *  whose sheet and tracks are Normal mode's; back on Tracks, the pick comes back. */
    fun tabMode(picked: MapMode, tab: PanelTab): MapMode = if (tab == PanelTab.TRACKS) picked else MapMode.NORMAL

    /** Whether a tap on [tapped]'s button while [current] is on opens Fog's level menu: a tap on
     *  Fog while it's on. */
    fun fogMenuOnTap(tapped: MapMode, current: MapMode): Boolean = tapped == MapMode.FOG && current == MapMode.FOG

    /** The tab the bottom bar's [asked] switches the panel to from [current], or null for none:
     *  Tracks on Tracks changes nothing, so a sheet left open stays open. */
    fun tabRequest(current: PanelTab, asked: PanelTab): PanelTab? =
        if (asked == PanelTab.TRACKS && current == PanelTab.TRACKS) null else asked

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
     *  is away, so an image can show the Checked tracks' stats (`docs/SPEC.md` FR-4.7). */
    fun checkedExportShown(editing: Boolean, selectionShown: Boolean): Boolean = !editing && selectionShown

    /** Whether rows are being checked where the selection bar can show: the sheet up on the
     *  Tracks tab, no Edit window. */
    fun selectionShown(sheetVisible: Boolean, selecting: Boolean, tab: PanelTab, editOpen: Boolean): Boolean =
        sheetVisible && selecting && tab == PanelTab.TRACKS && !editOpen

    /** The list's summary at the sheet's head: the Tracks tab's, in Normal mode, unless the
     *  selected track's card has the head. */
    fun summaryShown(normal: Boolean, tab: PanelTab, showsCard: Boolean): Boolean =
        normal && tab == PanelTab.TRACKS && !showsCard

    /** The sheet: Normal mode's, and the Sync tab's even while recording, so what's on the phone
     *  can be sent mid-walk; hidden while an editor has the screen. */
    fun sheetShown(normal: Boolean, sessionReady: Boolean, mode: MapMode, tab: PanelTab, editing: Boolean): Boolean {
        val syncing = sessionReady && mode == MapMode.NORMAL && tab == PanelTab.SYNC
        return (normal || syncing) && !editing
    }

    /** Whether [next] may replace the notice up: a less important one never replaces a more important one. */
    fun noticeReplaces(current: MapNotice?, next: MapNotice): Boolean = current == null || current.ordinal >= next.ordinal

    /** The empty notice points a real account with nothing on the map at Sync, until this phone
     *  closes it for the account. The demo account has history and can't sync. */
    fun emptyNoticeShown(empty: Boolean, demo: Boolean, closed: Boolean): Boolean = empty && !demo && !closed

    /** Whether the map draws the routes through the Tracks tab's filters on [tab]: not on
     *  Library or its Sync, where it shows every track (`testdata/client-rules/map-tracks-filters.json`). */
    fun tracksFiltersApply(tab: PanelTab): Boolean = tab != PanelTab.LIBRARY && tab != PanelTab.SYNC

    /** The empty and capped notices step aside while recording and on the Sync tab, whose lists
     *  aren't the area's; failures stay up. */
    fun noticeShown(kind: MapNotice?, recording: Boolean, onSync: Boolean): Boolean =
        kind != null && !((kind == MapNotice.EMPTY || kind == MapNotice.CAPPED) && (recording || onSync))
}
