package dev.holdmytrack.android.map

import android.view.View
import androidx.core.view.isVisible
import dev.holdmytrack.android.R
import dev.holdmytrack.android.net.Track
import dev.holdmytrack.android.net.HoldMyTrackApi
import dev.holdmytrack.android.panel.TracksPanel
import org.maplibre.android.camera.CameraPosition
import org.maplibre.android.camera.CameraUpdateFactory
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.geometry.LatLngBounds
import org.maplibre.android.maps.MapLibreMap

/**
 * Moves the camera onto tracks, into the map left showing between the top row and the sheet,
 * an editor or the Dates sheet ([FrameRules]): any box ([flyTo]), and the opening view once per session ([open]).
 */
class CameraFramer(
    view: View,
    private val panel: TracksPanel,
    private val map: () -> MapLibreMap?,
    private val recording: () -> Boolean,
    private val tripOpen: () -> Boolean,
    /** The top on screen of a sheet over the map in a window of its own (`panel/MapSheet`), or
     *  null when none is open. */
    private val sheetTop: () -> Int?,
    /** What [open] found: whether the account has no track yet. */
    private val onEmpty: (Boolean) -> Unit,
) {
    private val root: View = view.findViewById(R.id.map_root)
    private val topBar: View = view.findViewById(R.id.top_bar)
    private val topStart: View = view.findViewById(R.id.top_start)
    private val topChrome: View = view.findViewById(R.id.top_chrome)
    private val banner: View = view.findViewById(R.id.capture_banner)
    private val sheet: View = view.findViewById(R.id.tracks_sheet)
    private val editors: List<View> = listOf(R.id.edit_window, R.id.private_editor).map { view.findViewById(it) }
    private val density = view.resources.displayMetrics.density

    /** Whether the opening view has run this session. Once only: framing on every resume would
     *  fight the user for the camera. */
    var framed = false

    /** The camera is on the app's own flight, which the list doesn't follow ([consumeAppFlight]). */
    private var appFlight = false

    /**
     * The opening view (`docs/SPEC.md` FR-4.4), once per session: the newest five tracks framed at
     * zoom 12, or fewer when five don't fit ([OpeningView]), the list then asked about wherever
     * the camera is ([onOpened]). The newest few are asked for alone, since no area is known yet.
     */
    fun open(onOpened: () -> Unit) {
        if (framed) return onOpened()
        framed = true
        HoldMyTrackApi.areaTracks(null, from = null, to = null, limit = OpeningView.TRACKS) { result ->
            val page = result.getOrNull()
            if (page == null) return@areaTracks onOpened()
            val boxes = FitBoxes.of(page.tracks)
            val instance = map()
            val view = OpeningView.of(boxes, root.width / density.toDouble(), root.height / density.toDouble())
            onEmpty(view == null)
            if (view != null && instance != null && MapChromeRules.opens(recording(), tripOpen())) {
                appFlight = true
                instance.moveCamera(CameraUpdateFactory.newLatLngZoom(LatLng(view.lat, view.lon), view.zoom))
            }
            onOpened()
        }
    }

    /** [open] again, for an account that had nothing to frame. */
    fun openAgain(onOpened: () -> Unit) {
        framed = false
        open(onOpened)
    }

    /** Whether the camera just settled from the app's own flight, which this answer uses up. */
    fun consumeAppFlight(): Boolean = appFlight.also { appFlight = false }

    /** Frames [tracks] as Show on map does ([FitBoxes.selection]). */
    fun flyTo(tracks: List<Track>) {
        flyTo(BoxUnion.of(FitBoxes.selection(tracks)) ?: return)
    }

    /**
     * Flies to fit [box] (`[west, south, east, north]`, east past 180 across the antimeridian).
     * The zoom is capped: a tiny extent would land past the basemap's z14 data, on grey.
     */
    fun flyTo(box: DoubleArray, maxZoom: Double = MAX_ZOOM, onLanded: (() -> Unit)? = null) {
        val instance = map() ?: return
        val bounds = LatLngBounds.from(box[3], box[2], box[1], box[0])
        val editor = editors.firstOrNull { it.isVisible }
        // Above where the sheet rests or is heading, not mid-drag: View on map collapses it and
        // flies at once.
        val inMap = when {
            editor != null -> root.height - editor.top
            sheet.isVisible -> root.height - panel.restingTop(root.height)
            else -> 0
        }
        val inWindow = sheetTop()?.let { top -> IntArray(2).also(root::getLocationOnScreen)[1] + root.height - top } ?: 0
        val covered = maxOf(inMap, inWindow)
        val padding = FrameRules.padding(
            rootHeight = root.height,
            // The mode toggle's column, not the whole row: the rail of buttons at the end is
            // taller, and fitting below it squeezed every fit into a strip above the sheet.
            chromeBottom = topChrome.top + topBar.top + topStart.bottom,
            bannerBottom = if (banner.isVisible) topChrome.top + banner.bottom else null,
            coveredBelow = covered,
            minSpanPx = (MIN_SPAN_DP * density).toInt(),
        )
        val fitted = instance.getCameraForLatLngBounds(bounds, padding) ?: return
        val target = CameraPosition.Builder(fitted)
            .zoom(minOf(fitted.zoom, maxZoom))
            .build()
        appFlight = true
        instance.animateCamera(CameraUpdateFactory.newCameraPosition(target), DURATION_MS, object : MapLibreMap.CancelableCallback {
            override fun onFinish() {
                onLanded?.invoke()
            }

            // A gesture took the camera over: the list follows where it settles.
            override fun onCancel() {
                appFlight = false
            }
        })
    }

    companion object {
        const val MAX_ZOOM = 15.0

        /** The least height of map a fit keeps between the top row and the sheet. */
        private const val MIN_SPAN_DP = 96
        private const val DURATION_MS = 900
    }
}
