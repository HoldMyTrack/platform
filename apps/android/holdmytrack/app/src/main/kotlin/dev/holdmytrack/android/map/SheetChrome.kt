package dev.holdmytrack.android.map

import android.view.View
import androidx.activity.OnBackPressedCallback
import androidx.core.view.isVisible
import dev.holdmytrack.android.R
import dev.holdmytrack.android.panel.TracksPanel

/**
 * The Tracks sheet and the chrome that follows it ([MapChromeRules]): the sheet itself, the
 * list's summary at its head, and the rail. Back ends selecting, then collapses an open sheet.
 */
class SheetChrome(
    view: View,
    private val panel: TracksPanel,
    /** Normal mode, session ready, not recording ([MapChromeRules.normalMode]). */
    private val normalMode: () -> Boolean,
    private val sessionReady: () -> Boolean,
    private val mode: () -> MapMode,
    private val editOpen: () -> Boolean,
    private val privacyEditing: () -> Boolean,
    /** The sheet came to rest or its head changed height. */
    private val onSheetMoved: () -> Unit,
    /** After every [render], for what else follows the sheet. */
    private val onRendered: () -> Unit,
    private val dismissLayers: () -> Unit,
) {
    private val sheet: View = view.findViewById(R.id.tracks_sheet)
    private val summaryHead: View = view.findViewById(R.id.panel_summary_head)
    private val rail: View = view.findViewById(R.id.map_rail)

    /** Back closes an open sheet before it leaves the map. */
    val collapseOnBack = object : OnBackPressedCallback(false) {
        override fun handleOnBackPressed() = panel.setExpanded(false)
    }

    /** Back unchecks every row, ending selecting, before it does anything else on the map. */
    val endSelectingOnBack = object : OnBackPressedCallback(false) {
        override fun handleOnBackPressed() = panel.endSelecting()
    }

    /** The sheet is Normal mode's only (`docs/SPEC.md` FR-4.2), hidden while recording, and waits
     *  for the session. The summary at its head is the Tracks tab's. */
    fun render() {
        val normal = normalMode()
        // The toolbar takes the summary's place at the head.
        summaryHead.isVisible = MapChromeRules.summaryShown(normal, panel.tab, panel.showsActions)
        // An editor over the map hides the sheet. The Sync tab stays while recording: what's on
        // the phone can be sent mid-walk.
        sheet.isVisible = MapChromeRules.sheetShown(normal, sessionReady(), mode(), panel.tab, editOpen() || privacyEditing())
        if (!normal) panel.dismissPopups()
        onSheetChanged()
        renderSelecting()
        onRendered()
    }

    /** Back ends selecting while rows are checked in view ([MapChromeRules.selectionShown]). */
    fun renderSelecting() {
        endSelectingOnBack.isEnabled = MapChromeRules.selectionShown(sheet.isVisible, panel.selecting, panel.tab, editOpen())
    }

    /** The rail (Layers, Find my location), hidden while an editor is open over the map. */
    fun renderRail() {
        val editing = editOpen() || privacyEditing()
        rail.isVisible = MapChromeRules.railShown(editing)
        if (editing) dismissLayers()
    }

    /** The sheet came to rest or its head changed height: what follows its head moves, and Back
     *  closes it while it's open. */
    fun onSheetChanged() {
        onSheetMoved()
        collapseOnBack.isEnabled = sheet.isVisible && panel.expanded && !editOpen()
    }
}
