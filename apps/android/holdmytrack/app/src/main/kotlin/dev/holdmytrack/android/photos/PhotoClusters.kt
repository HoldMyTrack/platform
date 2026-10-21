package dev.holdmytrack.android.photos

import dev.holdmytrack.android.map.MapOverlays

/** How photo markers are drawn at a zoom ([PhotoClusters.markerSize]). */
enum class MarkerSize { HIDDEN, SMALL, FULL }

/** A marker's place on screen, in pixels. */
data class ScreenPoint(val id: String, val x: Float, val y: Float)

/** One marker's photos, in the order given (route order) — the first being the one it shows,
 *  and where it sits. */
data class PhotoCluster(val ids: List<String>, val x: Float, val y: Float)

/**
 * Grouping photo markers that would overlap on screen (`apps/android/docs/SPEC.md` FR-2.10) — the
 * photos of a whole trip seen zoomed out, or several taken at one spot. Done in screen pixels after
 * each move of the map, since what overlaps depends on the zoom; tens of photos per route make that
 * cheap. The web's `photoClusters.ts`; both run `testdata/client-rules/photo-clusters.json` and
 * `photo-marker-size.json`.
 */
object PhotoClusters {

    /** How close two markers' centres may be, in dp, before they're one group: a little under
     *  a marker's width (36dp), so markers that would merely touch stay apart. */
    const val RADIUS_DP = 32f

    /** The same for a small marker (22dp). */
    const val SMALL_RADIUS_DP = 18f

    /** From this zoom up a marker is drawn full size; below it, small, so the tracks — thin
     *  lines across a whole region at that scale — still show under the photos. */
    const val FULL_ZOOM = 10.0

    /** How photo markers are drawn at [zoom]: not at all where
     *  tracks aren't either (below [MapOverlays.TRACKS_MIN_ZOOM]) — a photo would sit over a
     *  continent with no route under it — small below [FULL_ZOOM], full size from it. */
    fun markerSize(zoom: Double): MarkerSize = when {
        zoom < MapOverlays.TRACKS_MIN_ZOOM -> MarkerSize.HIDDEN
        zoom < FULL_ZOOM -> MarkerSize.SMALL
        else -> MarkerSize.FULL
    }

    /**
     * Greedy grouping in the given order: each point joins the first group whose anchor — its
     * first point, where the group's marker sits — is within [radius], or starts a group of its
     * own. Anchoring on a real point rather than a moving centroid keeps a group's marker on the
     * route and doesn't chain a long run of close photos into one group.
     */
    fun cluster(points: List<ScreenPoint>, radius: Float): List<PhotoCluster> {
        val anchors = ArrayList<ScreenPoint>()
        val members = ArrayList<MutableList<String>>()
        for (p in points) {
            val near = anchors.indexOfFirst { (it.x - p.x) * (it.x - p.x) + (it.y - p.y) * (it.y - p.y) <= radius * radius }
            if (near >= 0) {
                members[near] += p.id
            } else {
                anchors += p
                members += mutableListOf(p.id)
            }
        }
        return anchors.mapIndexed { i, a -> PhotoCluster(members[i], a.x, a.y) }
    }

    /** The markers at [size]: [points] grouped as they'd overlap, [radius] scaled by [unit] (pixels
     *  per dp), except [loneId], which keeps a marker of its own after the rest. The live map's
     *  markers and the export's ([layout]) both come from here. */
    fun groups(points: List<ScreenPoint>, size: MarkerSize, loneId: String?, unit: Float = 1f): List<PhotoCluster> {
        val radius = (if (size == MarkerSize.SMALL) SMALL_RADIUS_DP else RADIUS_DP) * unit
        val groups = cluster(points.filter { it.id != loneId }, radius).toMutableList()
        points.firstOrNull { it.id == loneId }?.let { groups += PhotoCluster(listOf(it.id), it.x, it.y) }
        return groups
    }

    /**
     * The markers an exported image draws (root `docs/SPEC.md` FR-4.10): grouped and sized as the
     * screen does at [zoom], from [points] in dp from the frame's top-left, then scaled to the image
     * by [scale] (pixels per dp). A marker wholly outside the [width] × [height] frame is left out;
     * the active one comes last, to be drawn on top. The web's `photoMarkerLayout`.
     */
    fun layout(points: List<ScreenPoint>, zoom: Double, activeId: String?, loneId: String?, width: Float, height: Float, scale: Float): List<PhotoMarkerPlacement> {
        val size = markerSize(zoom)
        if (size == MarkerSize.HIDDEN) return emptyList()
        val small = size == MarkerSize.SMALL
        val look = PhotoMarkerLook.of(small)
        val placed = groups(points, size, loneId).map { group ->
            val active = activeId != null && activeId in group.ids
            PhotoMarkerPlacement(group.ids, group.x, group.y, if (active) look.activeDiameter else look.diameter, active, small)
        }.filter { m -> m.x + m.diameter / 2 >= 0 && m.x - m.diameter / 2 <= width && m.y + m.diameter / 2 >= 0 && m.y - m.diameter / 2 <= height }
        return (placed.filter { !it.active } + placed.filter { it.active }).map { it.copy(x = it.x * scale, y = it.y * scale, diameter = it.diameter * scale) }
    }
}

/** One marker in an exported image, in its pixels ([PhotoClusters.layout]). */
data class PhotoMarkerPlacement(val ids: List<String>, val x: Float, val y: Float, val diameter: Float, val active: Boolean, val small: Boolean)
