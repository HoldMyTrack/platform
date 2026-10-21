package dev.holdmytrack.android.photos

/**
 * How a photo marker looks, in dp: what the live map's markers (`map/PhotoMarkers`) and the
 * exported image's (`export/ExportPhotos`) both draw, so the two can't drift. The web's
 * `apps/web/src/map/photoMarkerLook.ts`, with the same values.
 */
object PhotoMarkerLook {

    data class Size(
        /** The circle's diameter, and while its photo is open or in hand. */
        val diameter: Float,
        val activeDiameter: Float,
        /** The ring, and while open or in hand. */
        val border: Float,
        val activeBorder: Float,
        /** How far up and right each of a group's two cards behind it shows. */
        val stack: Float,
        /** A group's count: its pill's height, font size and side padding, and how far it
         *  overhangs the circle at the top and right. */
        val countHeight: Float,
        val countFont: Float,
        val countPad: Float,
        val countTop: Float,
        val countRight: Float,
    )

    val FULL = Size(36f, 52f, 2f, 2f, 3f, 18f, 11f, 4f, 8f, 10f)

    /** Zoomed out ([PhotoClusters.markerSize]). */
    val SMALL = Size(22f, 36f, 1.5f, 2f, 2f, 14f, 10f, 3f, 7f, 9f)

    fun of(small: Boolean): Size = if (small) SMALL else FULL
}
