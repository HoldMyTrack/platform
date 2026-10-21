package dev.holdmytrack.android.map

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Outline
import android.view.View
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import android.widget.FrameLayout
import dev.holdmytrack.android.R
import dev.holdmytrack.android.photos.MarkerSize
import dev.holdmytrack.android.photos.PhotoClusters
import dev.holdmytrack.android.photos.PhotoImages
import dev.holdmytrack.android.photos.ScreenPoint
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.maps.MapLibreMap

/** One marker: a saved photo — [thumbPath], its thumbnail's API path — or one the Photos tab
 *  is placing before it's uploaded, with its local [thumb]. */
data class PhotoMarkerItem(
    val id: String,
    val lon: Double,
    val lat: Double,
    val caption: String?,
    val thumbPath: String? = null,
    val thumb: Bitmap? = null,
)

/** How the Photos tab's unsaved changes alter the markers: photos moved or added ([upserts],
 *  replacing a saved one with the same id), photos to be deleted ([hidden]), and the one in
 *  hand ([activeId], drawn larger and never grouped). */
data class PhotoMarkerOverlay(
    val upserts: List<PhotoMarkerItem>,
    val hidden: Set<String>,
    val activeId: String?,
)

/**
 * Photo markers (`apps/android/docs/SPEC.md` FR-2.10), the web's `apps/web/src/map/photos.ts`: each photo of
 * the selected activity or the open Story as its own thumbnail in a round frame, at its point on
 * the track — or, where several would overlap on screen, one marker for the group: its first
 * photo, stacked, with a count ([PhotoClusters]). The groups are worked out again whenever the
 * camera comes to rest ([regroup]), so zooming in splits them; meanwhile [place] keeps every
 * marker on its point as the camera moves. Zoomed out the markers are small, and below the zoom
 * tracks start at there are none ([PhotoClusters.markerSize]).
 *
 * Views in [layer] — a pass-through layer over the map, under its chrome — rather than a symbol
 * layer, as the web's are HTML markers: there are tens of them, not thousands, and each shows
 * its own image, which a symbol layer would need added to the style as an icon, and again after
 * every style load. A marker's tap is the view's, so it never reaches the map's own tap handling
 * and leaves the selection as it was.
 */
class PhotoMarkers(private val layer: FrameLayout, private val onOpen: (List<String>) -> Unit) {

    private val context = layer.context
    private val density = layer.resources.displayMetrics.density
    private var map: MapLibreMap? = null
    private var items: List<PhotoMarkerItem> = emptyList()
    private var activeId: String? = null
    private var loneId: String? = null
    /** Off while the export frames the map: the markers stay in sight, and a tap goes to the map. */
    private var interactive = true

    /** One view per group, keyed by its photos' ids. */
    private val markers = LinkedHashMap<String, PhotoMarkerView>()

    /** What to show: [items] in route order, the one open or in hand ([activeId]) drawn larger,
     *  and [loneId] — the photo the Photos tab is moving — kept out of every group. */
    fun set(instance: MapLibreMap?, items: List<PhotoMarkerItem>, activeId: String?, loneId: String?) {
        map = instance
        this.items = items
        this.activeId = activeId
        this.loneId = loneId
        regroup()
    }

    /** The groups again, from where the photos are on screen now. */
    fun regroup() {
        val instance = map
        val size = instance?.let { PhotoClusters.markerSize(it.cameraPosition.zoom) } ?: MarkerSize.HIDDEN
        if (instance == null || items.isEmpty() || size == MarkerSize.HIDDEN) {
            clear()
            return
        }
        val small = size == MarkerSize.SMALL
        val projection = instance.projection
        val byId = items.associateBy { it.id }
        val groups = PhotoClusters.groups(
            items.map {
                val p = projection.toScreenLocation(LatLng(it.lat, it.lon))
                ScreenPoint(it.id, p.x, p.y)
            },
            size,
            loneId,
            density,
        ).map { it.ids }

        val wanted = groups.associateBy { it.joinToString("|") }
        markers.keys.filter { it !in wanted }.forEach { key -> markers.remove(key)?.let(layer::removeView) }
        for ((key, ids) in wanted) {
            val item = byId.getValue(ids.first())
            val view = markers.getOrPut(key) {
                PhotoMarkerView(context).also { view ->
                    view.setOnClickListener { onOpen(view.ids) }
                    view.isClickable = interactive
                    layer.addView(view, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
                }
            }
            view.bind(item, ids, activeId != null && activeId in ids, small)
        }
        // The one in hand or open over the rest.
        markers.values.filter { it.active }.forEach { it.bringToFront() }
        place()
    }

    /** Every marker on its point again — on each camera move. */
    fun place() {
        val instance = map ?: return
        val projection = instance.projection
        for (view in markers.values) {
            val item = view.item ?: continue
            val p = projection.toScreenLocation(LatLng(item.lat, item.lon))
            view.translationX = p.x - view.side / 2f
            view.translationY = p.y - view.side / 2f
        }
    }

    fun clear() {
        markers.values.forEach(layer::removeView)
        markers.clear()
    }

    fun setInteractive(on: Boolean) {
        interactive = on
        markers.values.forEach { it.isClickable = on }
    }

    /** What [set] last showed, for the image export to draw the same. */
    fun snapshot(): Snapshot = Snapshot(items, activeId, loneId)

    data class Snapshot(val items: List<PhotoMarkerItem>, val activeId: String?, val loneId: String?)
}

/**
 * One marker, drawn by [PhotoMarkerPainter]. The view is a square [side] wide with room around
 * the circle for the stack and the count, so its touch target is never under 48dp.
 */
@SuppressLint("ViewConstructor")
private class PhotoMarkerView(context: Context) : View(context) {

    private val density = resources.displayMetrics.density
    private val painter = PhotoMarkerPainter(context)
    var item: PhotoMarkerItem? = null
        private set
    var ids: List<String> = emptyList()
        private set
    var active = false
        private set
    private var small = false
    private var bitmap: Bitmap? = null

    private val diameter: Float
        get() = painter.diameter(active, small, density)

    /** The view's width and height: the circle and room for the stack and the count, and never
     *  under a 48dp touch target. */
    val side: Int
        get() = maxOf(diameter + 2 * PAD_DP * density, TARGET_DP * density).toInt()

    init {
        isClickable = true
        isFocusable = true
        elevation = 4 * density
        // The shadow is the circle's, not the square view's.
        outlineProvider = object : ViewOutlineProvider() {
            override fun getOutline(view: View, outline: Outline) {
                val r = diameter / 2
                val c = side / 2f
                outline.setOval((c - r).toInt(), (c - r).toInt(), (c + r).toInt(), (c + r).toInt())
            }
        }
    }

    fun bind(next: PhotoMarkerItem, groupIds: List<String>, isActive: Boolean, isSmall: Boolean) {
        val resized = isActive != active || isSmall != small
        small = isSmall
        val sameImage = item?.let { it.thumbPath == next.thumbPath && it.thumb === next.thumb } == true
        item = next
        ids = groupIds
        active = isActive
        contentDescription = if (groupIds.size > 1) {
            resources.getQuantityString(R.plurals.photos_marker_group, groupIds.size, groupIds.size)
        } else {
            next.caption ?: resources.getString(R.string.photos_marker)
        }
        if (!sameImage) {
            bitmap = next.thumb ?: next.thumbPath?.let(PhotoImages::cached)
            val path = next.thumbPath
            if (bitmap == null && path != null) {
                PhotoImages.thumb(path) { loaded ->
                    if (item?.thumbPath == path) {
                        bitmap = loaded
                        invalidate()
                    }
                }
            }
        }
        if (resized) {
            requestLayout()
            invalidateOutline()
        }
        invalidate()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) = setMeasuredDimension(side, side)

    override fun onDraw(canvas: Canvas) {
        val c = side / 2f
        painter.draw(canvas, c, c, ids.size, bitmap, active, small, density)
    }

    private companion object {
        /** Room around the circle: the stack's 6dp and the badge's overhang, and a 48dp target. */
        const val PAD_DP = 12f
        const val TARGET_DP = 48f
    }
}
