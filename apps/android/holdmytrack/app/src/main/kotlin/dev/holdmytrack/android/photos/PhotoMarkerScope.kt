package dev.holdmytrack.android.photos

import dev.holdmytrack.android.map.Geo
import dev.holdmytrack.android.map.MapMode
import dev.holdmytrack.android.map.PhotoMarkerItem
import dev.holdmytrack.android.map.PhotoMarkerOverlay
import dev.holdmytrack.android.net.Photo

/**
 * Which photos the map shows and what a marker's tap does (`apps/docs/SPEC.md` FR-2.10).
 * The web's `photoMarkerItems.ts`; both run `testdata/client-rules`.
 */
object PhotoMarkerScope {
    /** A group spread wider than this, in metres, zooms in to split; a tighter one opens its popup. */
    const val GROUP_SPREAD_M = 15.0

    /** How far a group's tap zooms in: where [GROUP_SPREAD_M] is wider than a marker. */
    const val GROUP_MAX_ZOOM = 19.0

    /** Whose photos show, in Normal mode only: the Edit window's single track (none for a
     *  group), else the selected track, else the open Trip. As `"track:<id>"` or `"trip:<id>"`. */
    fun scope(mode: MapMode, editOpen: Boolean, editSingleId: String?, focused: String?, tripId: String?): String? = when {
        mode != MapMode.NORMAL -> null
        editOpen -> editSingleId?.let { "track:$it" }
        focused != null -> "track:$focused"
        tripId != null -> "trip:$tripId"
        else -> null
    }

    /** Whether markers show: a scope, no recording, the Route tab not open, and a track
     *  scope's route not hidden. */
    fun shown(scope: String?, recording: Boolean, showingRoute: Boolean, mapHidden: Set<String>): Boolean {
        val trackScope = scope?.removePrefix("track:")?.takeIf { scope.startsWith("track:") }
        return scope != null && !recording && !showingRoute && trackScope !in mapHidden
    }

    /** The scope's located photos on visible routes, with the Photos tab's unsaved changes merged in. */
    fun markers(photos: List<Photo>, mapHidden: Set<String>, overlay: PhotoMarkerOverlay?): List<PhotoMarkerItem> {
        val items = photos.mapNotNull { p ->
            val lat = p.lat ?: return@mapNotNull null
            val lon = p.lon ?: return@mapNotNull null
            if (p.trackId in mapHidden) return@mapNotNull null
            PhotoMarkerItem(p.id, lon, lat, p.caption, thumbPath = p.thumbUrl)
        }
        if (overlay == null) return items
        val upserts = overlay.upserts.associateBy { it.id }
        val kept = items.filter { it.id !in overlay.hidden }.map { upserts[it.id] ?: it }
        val keptIds = kept.mapTo(HashSet()) { it.id }
        return kept + overlay.upserts.filter { it.id !in keptIds }
    }

    /** A group's tap: its bounds `[west, south, east, north]` to fit when spread wider than
     *  [GROUP_SPREAD_M], else null to open the popup. [points] are `(lat, lon)`. */
    fun groupFit(points: List<Pair<Double, Double>>): DoubleArray? {
        val spread = points.maxOfOrNull { a -> points.maxOf { b -> Geo.haversineM(a.first, a.second, b.first, b.second) } } ?: 0.0
        if (points.size <= 1 || spread <= GROUP_SPREAD_M) return null
        return doubleArrayOf(points.minOf { it.second }, points.minOf { it.first }, points.maxOf { it.second }, points.maxOf { it.first })
    }
}
