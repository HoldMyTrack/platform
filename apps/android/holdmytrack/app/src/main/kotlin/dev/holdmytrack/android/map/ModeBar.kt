package dev.holdmytrack.android.map

import dev.holdmytrack.android.panel.PanelTab
import android.view.View
import android.widget.TextView
import androidx.core.view.AccessibilityDelegateCompat
import androidx.core.view.ViewCompat
import androidx.core.view.accessibility.AccessibilityNodeInfoCompat
import androidx.core.view.isVisible
import com.google.android.material.button.MaterialButton
import dev.holdmytrack.android.R
import dev.holdmytrack.android.ui.LargeText

/** What the mode bar and its notices depend on, read at each render ([MapChromeRules]). */
data class ModeBarState(
    val mode: MapMode,
    val sessionReady: Boolean,
    val recording: Boolean,
    val editOpen: Boolean,
    val selectionShown: Boolean,
    /** Fog is still being re-rendered (`CoverageWatch`). */
    val coverageRendering: Boolean,
    /** The panel's tab: the toggle is the Map tab's. */
    val tab: PanelTab,
)

/**
 * The Normal / Fog of War toggle floating top-start, and what it says about the mode: Fog's
 * level on its button ([FogLevelMenu]), and that coverage is still being updated (`docs/SPEC.md` FR-4.2). A tap on Fog while it's on opens the level menu.
 */
class ModeBar(
    root: View,
    onPick: (MapMode) -> Unit,
    /** Fog's levels in the applied layers document, the camera's zoom, and a pick's lock and zoom. */
    levels: () -> List<FogLevels.Level>,
    zoom: () -> Double?,
    onLock: (locked: String?, zoomTo: Double?) -> Unit,
    private val state: () -> ModeBarState,
) {
    private val bar: View = root.findViewById(R.id.mode_bar)
    private val layersPanel: View = root.findViewById(R.id.layers_panel)
    private val coverageNotice: View = root.findViewById(R.id.coverage_notice)
    private val buttons: Map<MapMode, MaterialButton> = mapOf(
        MapMode.NORMAL to root.findViewById(R.id.mode_normal),
        MapMode.FOG to root.findViewById(R.id.mode_fog),
    )
    private val fogMenu = FogLevelMenu(buttons.getValue(MapMode.FOG), levels, zoom, onLock)

    init {
        // One choice of two: each reads as a radio button, "1 of 2" (map/MapModeButton).
        buttons.values.forEachIndexed { index, button -> (button as? MapModeButton)?.position = index }
        ViewCompat.setAccessibilityDelegate(bar, object : AccessibilityDelegateCompat() {
            override fun onInitializeAccessibilityNodeInfo(host: View, info: AccessibilityNodeInfoCompat) {
                super.onInitializeAccessibilityNodeInfo(host, info)
                info.setCollectionInfo(
                    AccessibilityNodeInfoCompat.CollectionInfoCompat.obtain(1, buttons.size, false, AccessibilityNodeInfoCompat.CollectionInfoCompat.SELECTION_MODE_SINGLE),
                )
            }
        })
        buttons.forEach { (value, button) ->
            button.setOnClickListener {
                val menu = value == MapMode.FOG && state().mode == MapMode.FOG
                onPick(value)
                if (menu) {
                    // Checkable, so the tap just unchecked it: Fog stays on, and the tap opens its menu.
                    button.isChecked = true
                    fogMenu.toggle()
                }
            }
            button.minWidth = ChromeInsets.minTouchTargetPx(button)
            button.minimumWidth = ChromeInsets.minTouchTargetPx(button)
        }
    }

    /** Checks [mode]'s button. */
    fun check(mode: MapMode) {
        buttons.forEach { (value, button) ->
            val active = value == mode
            button.isChecked = active
            renderLabel(button, active)
        }
    }

    /** The toggle shows once the session allows, on the Map tab, hidden while recording, editing or checking rows.
     *  Layers stays while recording: the base map and paths are about where the recording goes. */
    fun render() {
        val s = state()
        if (!s.sessionReady) return
        bar.isVisible = MapChromeRules.modeBarShown(s.recording, s.editOpen, s.selectionShown, s.tab)
        layersPanel.visibility = View.VISIBLE
        renderNotices()
    }

    /** Fog's level on its button and the coverage notice. */
    fun renderNotices() {
        renderFogLevel()
        renderCoverage()
    }

    /** "Your map is still being updated…" (`docs/SPEC.md` FR-4.2), in Fog while coverage renders. */
    fun renderCoverage() {
        val s = state()
        coverageNotice.isVisible = MapChromeRules.coverageNoticeShown(s.coverageRendering, s.mode, s.sessionReady, s.recording)
    }

    /** Fog's button names the level in view while Fog is on: called as the zoom or the lock moves,
     *  and once the layers document is applied. Its menu closes when Fog does. */
    fun renderFogLevel() {
        val fog = buttons.getValue(MapMode.FOG)
        val on = state().mode == MapMode.FOG
        if (!on) fogMenu.dismiss()
        val label = if (on) fogMenu.label() else fog.resources.getString(R.string.mode_fog).let { FogLevelMenu.Label(it, it) }
        if (fog.tag === label.text) return
        fog.tag = label.text
        fog.text = label.text
        renderLabel(fog, fog.isChecked)
        fog.contentDescription = label.description
    }

    /**
     * At a large font size only the active mode keeps its label; the others show icons
     * (`ui/LargeText`), still named for TalkBack. The layout's label is kept in the button's tag.
     */
    private fun renderLabel(button: MaterialButton, active: Boolean) {
        val label = (button.tag as? CharSequence) ?: button.text.also { button.tag = it }
        button.contentDescription = label
        if (!LargeText.isOn(button.resources)) return
        button.text = if (active) label else ""
        button.iconPadding = if (active) button.resources.getDimensionPixelSize(R.dimen.hmt_space_6) else 0
    }
}
