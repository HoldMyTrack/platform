package dev.holdmytrack.android.export

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import dev.holdmytrack.android.map.PhotoMarkerItem
import dev.holdmytrack.android.map.PhotoMarkerPainter
import dev.holdmytrack.android.photos.PhotoImages
import dev.holdmytrack.android.photos.PhotoMarkerPlacement

/**
 * The photo markers on screen, drawn into an exported image (root `docs/SPEC.md` FR-4.10) after
 * the map and before [ImageMarks], as the web's `exportPhotos.ts`. Where they go and how big is
 * [dev.holdmytrack.android.photos.PhotoClusters.layout]; how they look is [PhotoMarkerPainter],
 * the live markers' own.
 */
object ExportPhotos {

    /** The thumbnail each of [placements] shows, its group's first photo: an unsaved one's own,
     *  else cached or fetched. On the main thread, as [PhotoImages] is; one that can't load is
     *  left out, and its frame drawn empty. */
    fun loadThumbs(placements: List<PhotoMarkerPlacement>, items: List<PhotoMarkerItem>, onLoaded: (Map<String, Bitmap>) -> Unit) {
        val byId = items.associateBy { it.id }
        val shown = placements.mapNotNull { byId[it.ids.first()] }
        val thumbs = HashMap<String, Bitmap>()
        var waiting = shown.size
        if (waiting == 0) return onLoaded(thumbs)
        for (item in shown) {
            val done = { bitmap: Bitmap? ->
                bitmap?.let { thumbs[item.id] = it }
                if (--waiting == 0) onLoaded(thumbs)
            }
            val path = item.thumbPath
            when {
                item.thumb != null -> done(item.thumb)
                path != null -> PhotoImages.thumb(path, done)
                else -> done(null)
            }
        }
    }

    /** Draws [placements] onto [image], at [unit] pixels per dp. */
    fun draw(context: Context, image: Bitmap, placements: List<PhotoMarkerPlacement>, thumbs: Map<String, Bitmap>, unit: Float) {
        if (placements.isEmpty()) return
        val painter = PhotoMarkerPainter(context)
        val canvas = Canvas(image)
        for (m in placements) {
            painter.draw(canvas, m.x, m.y, m.ids.size, thumbs[m.ids.first()], m.active, m.small, unit, shadow = true)
        }
    }
}
