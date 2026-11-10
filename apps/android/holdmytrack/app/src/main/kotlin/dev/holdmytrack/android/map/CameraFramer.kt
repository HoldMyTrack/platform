package dev.holdmytrack.android.map

import android.view.View
import androidx.core.view.isVisible
import dev.holdmytrack.android.R
import dev.holdmytrack.android.net.Activity
import dev.holdmytrack.android.net.HoldMyTrackApi
import dev.holdmytrack.android.panel.ActivitiesPanel
import org.maplibre.android.camera.CameraPosition
import org.maplibre.android.camera.CameraUpdateFactory
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.geometry.LatLngBounds
import org.maplibre.android.maps.MapLibreMap

/**
 * Moves the camera onto activities, into the map left showing between the top row and the sheet
 * or an editor ([FrameRules]): any box ([flyTo]), and the opening view once per session ([open]).
 */
class CameraFramer(
    view: View,
    private val panel: ActivitiesPanel,
    private val map: () -> MapLibreMap?,
    private val recording: () -> Boolean,
    /** What [open] found: whether the account has no track yet. */
    private val onEmpty: (Boolean) -> Unit,
) {
    private val root: View = view.findViewById(R.id.map_root)
    private val topBar: View = view.findViewById(R.id.top_bar)
    private val topChrome: View = view.findViewById(R.id.top_chrome)
    private val banner: View = view.findViewById(R.id.capture_banner)
    private val sheet: View = view.findViewById(R.id.activities_sheet)
    private val editors: List<View> = listOf(R.id.edit_window, R.id.private_editor).map { view.findViewById(it) }
    private val density = view.resources.displayMetrics.density

    /** Whether the opening view has run this session. Once only: framing on every resume would
     *  fight the user for the camera. */
    var framed = false

    /** The camera is on the app's own flight, which the list doesn't follow ([consumeAppFlight]). */
    private var appFlight = false

    /**
     * The opening view (`docs/SPEC.md` FR-4.5), once per session: the newest five tracks framed at
     * zoom 12, or fewer when five don't fit ([OpeningView]), the list then asked about wherever
     * the camera is ([onOpened]). The newest few are asked for alone, since no area is known yet.
     */
    fun open(onOpened: () -> Unit) {
        if (framed) return onOpened()
        framed = true
        HoldMyTrackApi.areaActivities(null, DateFilter.ALL_TIME, OpeningView.ACTIVITIES) { result ->
            val page = result.getOrNull()
            if (page == null) return@areaActivities onOpened()
            val boxes = page.activities.filter { !it.pending }.mapNotNull { it.bbox }
            val instance = map()
            val view = OpeningView.of(boxes, root.width / density.toDouble(), root.height / density.toDouble())
            onEmpty(view == null)
            // Reopening the app mid-recording: the camera belongs to the live track.
            if (view != null && instance != null && !recording()) {
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

    /** Frames every one of [activities] that has a track. */
    fun flyTo(activities: List<Activity>) {
        flyTo(BoxUnion.of(activities.mapNotNull { it.bbox }) ?: return)
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
        val covered = when {
            editor != null -> root.height - editor.top
            sheet.isVisible -> root.height - panel.restingTop(root.height)
            else -> 0
        }
        val padding = FrameRules.padding(
            rootHeight = root.height,
            chromeBottom = topBar.bottom,
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
