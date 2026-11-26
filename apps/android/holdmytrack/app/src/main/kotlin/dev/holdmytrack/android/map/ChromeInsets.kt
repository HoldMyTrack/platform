package dev.holdmytrack.android.map

import android.os.Bundle
import android.view.View
import android.view.ViewGroup.MarginLayoutParams
import android.view.WindowInsets
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.isVisible
import dev.holdmytrack.android.R
import dev.holdmytrack.android.panel.MaxHeightScrollView
import dev.holdmytrack.android.panel.TracksPanel
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.MapView

/**
 * Keeps the map's floating chrome and MapLibre's own controls clear of the system bars, the top
 * row, the sheet and the editors along the bottom. `MainActivity`'s bottom bar takes the gesture
 * inset, so the only bottom inset here is the keyboard's, which the editors rise over.
 *
 * Required from API 35, which draws every app edge to edge: the top row's `LinearLayout` has no
 * `fitsSystemWindows`, so without this it sits under the status bar's icons. The map itself fills
 * the screen. Insets are added to each view's laid-out margin, and returned unconsumed.
 */
class ChromeInsets(
    private val root: View,
    private val topBar: View,
    private val topChrome: View,
    private val sheet: View,
    private val panel: TracksPanel,
    private val map: () -> MapLibreMap?,
) {
    /** A sheet along the bottom of the map: its header stays put, its fields scroll under it. */
    private class Sheet(val window: View, val header: View, val scroll: MaxHeightScrollView)

    /** The Edit window and the Private location editor. */
    private val sheets = listOf(
        Sheet(root.findViewById(R.id.edit_window), root.findViewById(R.id.edit_header), root.findViewById(R.id.edit_scroll)),
        Sheet(root.findViewById(R.id.private_editor), root.findViewById(R.id.private_editor_header), root.findViewById(R.id.private_editor_scroll)),
    )
    private val editors: List<View> = sheets.map { it.window }

    /** The keyboard's height, from the insets the map receives. The gesture bar's comes from the
     *  window's own: MainActivity hands its tabs the insets with that one taken out. */
    private var keyboard = 0

    /** The status bar's height. The inset and the map instance arrive in either order, so both
     *  paths call [applyCompassMargin]. */
    private var systemBarInsetTop = 0

    /** The compass's default top margin, captured once so repeated inset callbacks don't
     *  compound the status bar height. */
    private var compassBaseMarginTop = 0
    private var compassBaseMarginCaptured = false

    /** The logo's and attribution's default bottom margins, captured once. Trap: MapLibre
     *  restores its UI settings with the lift applied, so these are carried through [save]
     *  rather than captured again, which would lift twice. */
    private var logoBaseMarginBottom = 0
    private var attributionBaseMarginBottom = 0
    private var attributionBaseCaptured = false

    /** Starts following the insets and the layout of what the chrome must clear. */
    fun install() {
        val barTopMargin = (topBar.layoutParams as MarginLayoutParams).topMargin
        root.setOnApplyWindowInsetsListener { _, insets ->
            val bars = insets.getInsets(WindowInsets.Type.systemBars())
            (topBar.layoutParams as MarginLayoutParams).topMargin = barTopMargin + bars.top
            topBar.requestLayout()
            systemBarInsetTop = bars.top
            fitSheet(root.height)
            applyCompassMargin()
            // The keyboard rising or falling moves the editors with it.
            keyboard = WindowInsetsCompat.toWindowInsetsCompat(insets, root).getInsets(WindowInsetsCompat.Type.ime()).bottom
            placeEditors()
            insets
        }
        // The attribution sits above an editor, whose height is only known once it's laid out.
        for (editor in editors) {
            editor.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> applyAttributionMargin() }
        }
        // A sheet's cap takes off its header, whose height is 0 until it first lays out and
        // grows with a subtitle that wraps.
        for (sheet in sheets) {
            sheet.header.addOnLayoutChangeListener { _, _, top, _, bottom, _, oldTop, _, oldBottom ->
                if (bottom - top != oldBottom - oldTop) placeEditorsAfterLayout()
            }
        }
        // The compass sits below the top row, whose height is only known once it's laid out. The
        // attribution follows the sheet's head (`MapFragment.onSheetChanged`).
        topChrome.addOnLayoutChangeListener { _, _, top, _, bottom, _, oldTop, _, oldBottom ->
            applyCompassMargin()
            if (bottom - top != oldBottom - oldTop) placeEditorsAfterLayout()
        }
        root.addOnLayoutChangeListener { _, _, top, _, bottom, _, oldTop, _, oldBottom ->
            if (bottom - top != oldBottom - oldTop) {
                fitSheet(bottom - top)
                // An editor opens before the bottom bar hides, so the map grows after it's placed.
                placeEditorsAfterLayout()
            }
        }
    }

    /** Lets the expanded sheet reach the status bar, over the map's top row, in a map [height] tall:
     *  a long list is read at full height, and the row's buttons come back as the sheet drops. */
    private fun fitSheet(height: Int) {
        // Before the first layout the map has no height, and the layout listener comes next.
        if (height > 0) panel.setExpandedOffset(systemBarInsetTop, height)
    }

    /** Moves MapLibre's compass below the status bar and the top row, whose rail shares its top-end corner. */
    fun applyCompassMargin() {
        val instance = map() ?: return
        val settings = instance.uiSettings
        if (!compassBaseMarginCaptured) {
            compassBaseMarginTop = settings.compassMarginTop
            compassBaseMarginCaptured = true
        }
        // Below the top row, the notice in it; before the row is laid out, below the status bar.
        val belowTopBar = topBar.bottom
        settings.setCompassMargins(
            settings.compassMarginLeft,
            compassBaseMarginTop + maxOf(systemBarInsetTop, belowTopBar),
            settings.compassMarginRight,
            settings.compassMarginBottom,
        )
    }

    /**
     * Lifts MapLibre's logo and attribution above the collapsed sheet or an open editor: the
     * attribution is the basemap's ODbL credit and must stay visible (`FR-2.4`). An expanded
     * sheet covers them as it covers the map.
     */
    fun applyAttributionMargin() {
        val instance = map() ?: return
        val settings = instance.uiSettings
        if (!attributionBaseCaptured) {
            logoBaseMarginBottom = settings.logoMarginBottom
            attributionBaseMarginBottom = settings.attributionMarginBottom
            attributionBaseCaptured = true
        }
        val editor = editors.firstOrNull { it.isVisible }
        val above = when {
            editor != null -> root.height - editor.top
            sheet.isVisible -> panel.peekHeight
            else -> 0
        }
        settings.setLogoMargins(settings.logoMarginLeft, settings.logoMarginTop, settings.logoMarginRight, logoBaseMarginBottom + above)
        settings.setAttributionMargins(
            settings.attributionMarginLeft,
            settings.attributionMarginTop,
            settings.attributionMarginRight,
            attributionBaseMarginBottom + above,
        )
    }

    /**
     * Pads MapLibre's 21dp attribution "i" out to the 48dp touch target. It has no id, so it's
     * found by its content description. Padding goes on its right and top only, so the icon stays
     * put. Trap: the margins belong to [applyAttributionMargin]; padding evenly through them put
     * the icon over the MapLibre logo.
     */
    fun enlargeAttributionTarget(mapView: MapView) {
        val found = ArrayList<View>()
        mapView.findViewsWithText(
            found,
            mapView.context.getString(org.maplibre.android.R.string.maplibre_attributionsIconContentDescription),
            View.FIND_VIEWS_WITH_CONTENT_DESCRIPTION,
        )
        val icon = found.firstOrNull() ?: return
        val target = minTouchTargetPx(root)
        val padX = (target - icon.width).coerceAtLeast(0)
        val padY = (target - icon.height).coerceAtLeast(0)
        if (padX == 0 && padY == 0) return
        icon.setPadding(0, padY, padX, 0)
    }

    /** The editors are sheets along the screen's bottom (the bottom bar hides meanwhile)
     *  ([EditorPlacement]): reaching the edge, their padding clearing the gesture bar, or riding on
     *  the keyboard, so their header and its Save stay above it, their fields scrolling within
     *  what's left under the top row. Only while one is open: each runs this as it opens, and it
     *  runs again when the map's height, the top chrome or a header's height changes. */
    fun placeEditors() {
        val open = sheets.firstOrNull { it.window.isVisible }
        // The top row holds only its notices and banners while editing: drawn over the sheet,
        // so a sheet held at its scroll floor reaching under the row doesn't hide them.
        topChrome.translationZ = if (open != null) open.window.elevation + root.resources.displayMetrics.density else 0f
        if (open == null) return
        val res = root.resources
        val space = res.getDimensionPixelSize(R.dimen.hmt_space_10)
        val gesture = ViewCompat.getRootWindowInsets(root)?.getInsets(WindowInsetsCompat.Type.navigationBars())?.bottom ?: 0
        val screen = root.height.takeIf { it > 0 } ?: res.displayMetrics.heightPixels
        // The bottom of the top row and every notice and banner under it, in the map's own
        // coordinates.
        val top = maxOf(bottomIn(topChrome), systemBarInsetTop) + space
        val placement = EditorPlacement.sheet(gesture, keyboard)
        val window = open.window
        setBottomMargin(window, placement.margin)
        if (window.paddingBottom != placement.padding) {
            window.setPadding(window.paddingLeft, window.paddingTop, window.paddingRight, placement.padding)
        }
        open.scroll.maxHeight = EditorPlacement.scrollCap(
            res.displayMetrics.heightPixels,
            room = screen - placement.margin - top,
            // The scroll's own padding sits inside its capped height.
            chrome = open.header.height + placement.padding,
            min = (EditorPlacement.MIN_SCROLL_DP * res.displayMetrics.density).toInt(),
        )
    }

    /** Layout listeners run inside a layout pass, where a margin change would wait a frame. */
    private fun placeEditorsAfterLayout() {
        if (placePending) return
        placePending = true
        root.post {
            placePending = false
            placeEditors()
        }
    }

    private var placePending = false

    private fun setBottomMargin(card: View, bottom: Int) {
        val params = card.layoutParams as MarginLayoutParams
        if (params.bottomMargin == bottom) return
        params.bottomMargin = bottom
        card.layoutParams = params
    }

    /** [view]'s bottom edge, measured from the top of [root]. */
    private fun bottomIn(view: View): Int {
        val at = IntArray(2).also(view::getLocationInWindow)
        val origin = IntArray(2).also(root::getLocationInWindow)
        return at[1] - origin[1] + view.height
    }

    fun save(out: Bundle) {
        if (!attributionBaseCaptured) return
        out.putInt(STATE_LOGO_MARGIN, logoBaseMarginBottom)
        out.putInt(STATE_ATTRIBUTION_MARGIN, attributionBaseMarginBottom)
    }

    fun restore(saved: Bundle?) {
        if (saved?.containsKey(STATE_LOGO_MARGIN) != true) return
        logoBaseMarginBottom = saved.getInt(STATE_LOGO_MARGIN)
        attributionBaseMarginBottom = saved.getInt(STATE_ATTRIBUTION_MARGIN)
        attributionBaseCaptured = true
    }

    companion object {
        /** Material's and the platform's minimum touch target. */
        private const val MIN_TOUCH_TARGET_DP = 48

        private const val STATE_LOGO_MARGIN = "logo_margin"
        private const val STATE_ATTRIBUTION_MARGIN = "attribution_margin"

        /** The minimum touch target in pixels, rounded up. */
        fun minTouchTargetPx(view: View): Int = kotlin.math.ceil(MIN_TOUCH_TARGET_DP * view.resources.displayMetrics.density).toInt()
    }
}
