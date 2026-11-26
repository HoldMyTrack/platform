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
    /** Whether the empty map's pointer shows. */
    private val emptyShown: () -> Boolean,
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

    /** A read for the opening view is out; asked again meanwhile, it reads once more. */
    private var opening = false
    private var askedAgain = false

    /** Counts the camera's moves by the user or the app's flights, so an answer that lands after
     *  one leaves the camera where it went. */
    private var moves = 0

    /** The moves count when an open Trip held the opening view's move back ([OpeningView.Move.HOLD]). */
    private var heldAt: Int? = null

    /** How many more times a failed read for an empty map is made. */
    private var retriesLeft = 0
    private val retry = Runnable { pendingRetry?.let { again(it) } }
    private var pendingRetry: (() -> Unit)? = null

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
        opening = true
        val asked = moves
        HoldMyTrackApi.areaTracks(null, from = null, to = null, limit = OpeningView.TRACKS) { result ->
            opening = false
            val page = result.getOrNull()
            if (page == null) {
                if (OpeningView.retries(emptyShown(), retriesLeft)) {
                    retriesLeft--
                    pendingRetry = onOpened
                    root.postDelayed(retry, RETRY_MS)
                }
                return@areaTracks onOpened()
            }
            val boxes = FitBoxes.of(page.tracks)
            val instance = map()
            val view = OpeningView.of(boxes, root.width / density.toDouble(), root.height / density.toDouble())
            onEmpty(view == null)
            // Asked while this one read an empty account: something may have come since.
            if (askedAgain && view == null) {
                askedAgain = false
                return@areaTracks again(onOpened)
            }
            askedAgain = false
            when (OpeningView.move(view != null, recording(), tripOpen(), flightAsked = false, moved = moves != asked)) {
                OpeningView.Move.MOVE -> if (view != null && instance != null) {
                    appFlight = true
                    instance.moveCamera(CameraUpdateFactory.newLatLngZoom(LatLng(view.lat, view.lon), view.zoom))
                }
                OpeningView.Move.HOLD -> heldAt = moves
                OpeningView.Move.STAY -> Unit
            }
            onOpened()
        }
    }

    /** [open] again, for an account that had nothing to frame: one read at a time, or a later
     *  answer would pull the camera back from the user, and a failed one is made again while the
     *  empty map's pointer shows. */
    fun openAgain(onOpened: () -> Unit) {
        if (opening) {
            askedAgain = true
            return
        }
        retriesLeft = OpeningView.RETRIES
        again(onOpened)
    }

    private fun again(onOpened: () -> Unit) {
        if (opening) return
        framed = false
        open(onOpened)
    }

    /** A Trip closed: an opening view it held back is taken, unless the camera has moved since. */
    fun tripClosed(onOpened: () -> Unit) {
        val held = heldAt ?: return
        heldAt = null
        if (held == moves) again(onOpened)
    }

    /** The user moved the camera, or something other than the app's own fits did. */
    fun moved() {
        moves++
    }

    /** The map's view is going: a retry waiting would read for the next one's. */
    fun release() {
        root.removeCallbacks(retry)
        pendingRetry = null
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
        moves++
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
        private const val RETRY_MS = 5_000L
    }
}
