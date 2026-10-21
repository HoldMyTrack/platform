package dev.holdmytrack.android.map

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import dev.holdmytrack.android.R
import dev.holdmytrack.android.photos.PhotoMarkerLook

/**
 * Draws one photo marker ([PhotoMarkerLook]): the photo's thumbnail cropped into a circle in a ring
 * — the surface's colour, the accent's when active — and, for a group, two cards' edges showing
 * behind it and the count on its corner (the web's `.photo-marker--group` and
 * `.photo-marker__count`). The live marker view and the exported image (`export/ExportPhotos`)
 * both draw with it, at their own pixels per dp.
 */
class PhotoMarkerPainter(context: Context) {

    private val surface = context.getColor(R.color.hmt_surface)
    private val tint = context.getColor(R.color.hmt_surface_tint_strong)
    private val accent = context.getColor(R.color.hmt_accent)
    private val edgeColor = context.getColor(R.color.hmt_border_strong)

    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val edge = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; color = edgeColor }
    private val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
    private val image = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
    private val badge = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = accent }
    private val count = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = context.getColor(R.color.hmt_on_accent)
        typeface = Typeface.DEFAULT_BOLD
        textAlign = Paint.Align.CENTER
    }

    /** The circle's diameter in pixels, at [unit] pixels per dp. */
    fun diameter(active: Boolean, small: Boolean, unit: Float): Float =
        PhotoMarkerLook.of(small).let { if (active) it.activeDiameter else it.diameter } * unit

    /** A marker of [photos] photos centred on [cx], [cy]. With [shadow], the circle casts one, as
     *  the live view's elevation does; the view itself passes false. */
    fun draw(canvas: Canvas, cx: Float, cy: Float, photos: Int, bitmap: Bitmap?, active: Boolean, small: Boolean, unit: Float, shadow: Boolean = false) {
        val look = PhotoMarkerLook.of(small)
        val r = diameter(active, small, unit) / 2
        if (photos > 1) {
            // Two cards behind, up and to the right, as the web's stacked box-shadows.
            edge.strokeWidth = unit
            for (step in intArrayOf(2, 1)) {
                val d = look.stack * step * unit
                fill.color = surface
                canvas.drawCircle(cx + d, cy - d, r, fill)
                canvas.drawCircle(cx + d, cy - d, r, edge)
            }
        }
        val ringWidth = (if (active) look.activeBorder else look.border) * unit
        fill.color = tint
        if (shadow) fill.setShadowLayer(4 * unit, 0f, 2 * unit, Color.argb(56, 0, 0, 0))
        canvas.drawCircle(cx, cy, r, fill)
        fill.clearShadowLayer()
        bitmap?.let { b ->
            val inner = r - ringWidth
            val scale = (2 * inner) / minOf(b.width, b.height)
            val matrix = Matrix().apply {
                setScale(scale, scale)
                postTranslate(cx - b.width * scale / 2, cy - b.height * scale / 2)
            }
            image.shader = BitmapShader(b, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP).apply { setLocalMatrix(matrix) }
            canvas.drawCircle(cx, cy, inner, image)
        }
        ring.strokeWidth = ringWidth
        ring.color = if (active) accent else surface
        canvas.drawCircle(cx, cy, r - ringWidth / 2, ring)
        if (photos > 1) {
            val text = photos.toString()
            count.textSize = look.countFont * unit
            val h = look.countHeight * unit
            val w = maxOf(h, count.measureText(text) + 2 * look.countPad * unit)
            val right = cx + r + look.countRight * unit
            val top = cy - r - look.countTop * unit
            canvas.drawRoundRect(RectF(right - w, top, right, top + h), h / 2, h / 2, badge)
            canvas.drawText(text, right - w / 2, top + h / 2 - (count.descent() + count.ascent()) / 2, count)
        }
    }
}
