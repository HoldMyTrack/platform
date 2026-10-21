package dev.holdmytrack.android.map

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import androidx.core.graphics.ColorUtils
import dev.holdmytrack.android.R
import java.time.Month
import java.time.format.TextStyle
import kotlin.math.roundToInt

/**
 * The sheet's date scrubber, the web's slider track drawn natively (root `docs/SPEC.md` FR-6): a
 * thin track with the selection filled in the accent between two pill knobs, a tick on every
 * boundary between activity days, tall where a month starts, and the month's name under it
 * ([SliderRules.ticks]).
 *
 * It knows [slots] and two slot *boundaries*, [start] and [end] (0..slots, or -1 / slots + 1 for a
 * knob off either side of the window, which isn't drawn), and nothing about dates;
 * `DateRangeSlider` turns those into a selection. The whole view is the touch target, and a touch
 * is one of three gestures:
 *
 * - **A knob dragged.** A press within [HANDLE_GRAB_DP] of a drawn knob goes to [onPress] with
 *   its boundary, the drag to [onDrag] — unclamped, so a finger held past an edge can pull the
 *   window along — and the release to [onRelease].
 * - **A swipe.** A press anywhere else that moves sideways past the touch slop scrolls the window
 *   instead: [onSwipe] gets each whole slot the finger has moved, positive toward the past (the
 *   days follow the finger, as a list does), and the selection stays as it was.
 * - **A tap.** A press elsewhere let go without moving is [onPress] at the nearest boundary, then
 *   [onRelease] — the nearer knob moves there.
 */
class DayScrubberView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : View(context, attrs) {

    var slots = 0
        private set
    var start = 0
        private set
    var end = 0
        private set
    private var ticks: List<SliderRules.Tick> = emptyList()

    var onPress: ((boundary: Int) -> Unit)? = null
    var onDrag: ((boundary: Int) -> Unit)? = null
    var onRelease: (() -> Unit)? = null
    var onSwipe: ((days: Int) -> Unit)? = null

    private enum class Gesture { HANDLE, UNDECIDED, SWIPE }
    private var gesture: Gesture? = null
    private var downX = 0f
    /** Where the swipe's last whole slot was counted from. */
    private var swipeAnchorX = 0f
    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop

    private val density = resources.displayMetrics.density
    private val trackArea = TRACK_AREA_DP * density
    private val lineHeight = 4 * density
    private val dayTick = 8 * density
    private val monthTick = 16 * density
    private val knobHeight = 28 * density
    private val knobRadius = 6 * density
    private val knobBorder = 2 * density
    private val handleGrab = HANDLE_GRAB_DP * density
    private val labelSize = 11 * resources.displayMetrics.scaledDensity

    private val accent = context.getColor(R.color.hmt_accent)
    private val ink = context.getColor(R.color.hmt_ink)
    private val linePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = context.getColor(R.color.hmt_border_strong) }
    private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = accent }
    private val tickPaint = Paint().apply { strokeWidth = density }
    private val knobFill = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = context.getColor(R.color.hmt_surface)
        setShadowLayer(3 * density, 0f, density, Color.argb(48, 0, 0, 0))
    }
    private val knobStroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = knobBorder
        color = accent
    }
    private val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = labelSize
        color = context.getColor(R.color.hmt_ink_muted)
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
    }
    private val rect = RectF()
    private val locale = resources.configuration.locales[0]

    fun set(slots: Int, start: Int, end: Int, ticks: List<SliderRules.Tick>) {
        if (slots == this.slots && start == this.start && end == this.end && ticks == this.ticks) return
        this.slots = slots
        this.start = start
        this.end = end
        this.ticks = ticks
        invalidate()
    }

    private val left get() = paddingLeft.toFloat()
    private val slotWidth get() = if (slots == 0) 0f else (width - paddingLeft - paddingRight).toFloat() / slots

    private fun xOf(boundary: Int) = left + boundary.coerceIn(0, slots) * slotWidth

    /** The slot boundary nearest [x], not clamped to the window. */
    private fun boundaryAt(x: Float) = if (slotWidth == 0f) 0 else ((x - left) / slotWidth).roundToInt()

    override fun onDraw(canvas: Canvas) {
        if (slots == 0) return
        val cy = paddingTop + trackArea / 2
        val right = width - paddingRight.toFloat()
        rect.set(left, cy - lineHeight / 2, right, cy + lineHeight / 2)
        canvas.drawRoundRect(rect, lineHeight / 2, lineHeight / 2, linePaint)
        val s = start.coerceIn(0, slots)
        val e = end.coerceIn(0, slots)
        if (e > s) {
            rect.set(xOf(s), cy - lineHeight / 2, xOf(e), cy + lineHeight / 2)
            canvas.drawRoundRect(rect, lineHeight / 2, lineHeight / 2, fillPaint)
        }
        val labelY = paddingTop + trackArea + 2 * density - labelPaint.ascent()
        for (tick in ticks) {
            val x = xOf(tick.boundary)
            val half = (if (tick.monthStart) monthTick else dayTick) / 2
            tickPaint.color = when {
                tick.boundary in s..e && e > s -> accent
                tick.monthStart -> ColorUtils.setAlphaComponent(ink, 128)
                else -> ColorUtils.setAlphaComponent(ink, 71)
            }
            canvas.drawLine(x, cy - half, x, cy + half, tickPaint)
            val month = tick.month ?: continue
            val text = Month.of(month).getDisplayName(TextStyle.SHORT_STANDALONE, locale)
            canvas.drawText(text, if (tick.boundary == 0) left else x + 3 * density, labelY, labelPaint)
        }
        val knobWidth = (if (slotWidth < 18 * density) 12 else 16) * density
        for (boundary in intArrayOf(start, end)) {
            if (boundary < 0 || boundary > slots) continue
            val x = xOf(boundary)
            rect.set(x - knobWidth / 2, cy - knobHeight / 2, x + knobWidth / 2, cy + knobHeight / 2)
            canvas.drawRoundRect(rect, knobRadius, knobRadius, knobFill)
            rect.inset(knobBorder / 2, knobBorder / 2)
            canvas.drawRoundRect(rect, knobRadius, knobRadius, knobStroke)
        }
    }

    /** The drawn handle within reach of [x], if any — the nearer of the two. */
    private fun handleNear(x: Float): Int? =
        intArrayOf(start, end)
            .filter { it in 0..slots && Math.abs(xOf(it) - x) <= handleGrab }
            .minByOrNull { Math.abs(xOf(it) - x) }

    // A drag is a gesture over the whole scrubber, not a click; the buttons beside it and the
    // range written above it are what TalkBack reads.
    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!isEnabled || slots == 0) return false
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                // The sheet under it drags; a press here is the scrubber's.
                parent?.requestDisallowInterceptTouchEvent(true)
                downX = event.x
                val handle = handleNear(event.x)
                if (handle != null) {
                    gesture = Gesture.HANDLE
                    onPress?.invoke(handle)
                } else {
                    gesture = Gesture.UNDECIDED
                }
            }
            MotionEvent.ACTION_MOVE -> when (gesture) {
                Gesture.HANDLE -> onDrag?.invoke(boundaryAt(event.x))
                Gesture.UNDECIDED -> if (Math.abs(event.x - downX) > touchSlop) {
                    gesture = Gesture.SWIPE
                    swipeAnchorX = downX
                    swipe(event.x)
                }
                Gesture.SWIPE -> swipe(event.x)
                null -> Unit
            }
            MotionEvent.ACTION_UP -> {
                when (gesture) {
                    Gesture.HANDLE -> onRelease?.invoke()
                    Gesture.UNDECIDED -> {
                        onPress?.invoke(boundaryAt(event.x).coerceIn(0, slots))
                        onRelease?.invoke()
                    }
                    Gesture.SWIPE, null -> Unit
                }
                gesture = null
            }
            MotionEvent.ACTION_CANCEL -> {
                if (gesture == Gesture.HANDLE) onRelease?.invoke()
                gesture = null
            }
        }
        return true
    }

    /** Hands on each whole slot the finger has moved since the last one counted. */
    private fun swipe(x: Float) {
        if (slotWidth == 0f) return
        val moved = ((x - swipeAnchorX) / slotWidth).toInt()
        if (moved == 0) return
        swipeAnchorX += moved * slotWidth
        onSwipe?.invoke(moved)
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        // The track area, and the month labels under it.
        val wanted = (paddingTop + trackArea + 2 * density + labelPaint.descent() - labelPaint.ascent() + paddingBottom).toInt()
        setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), resolveSize(wanted, heightMeasureSpec))
    }

    private companion object {
        /** How near a knob a press grabs it rather than starting a swipe or a tap — 24dp, half a
         *  48dp target either side. */
        const val HANDLE_GRAB_DP = 24f

        /** The track's touch band, the knobs and ticks centred in it. */
        const val TRACK_AREA_DP = 40f
    }
}
