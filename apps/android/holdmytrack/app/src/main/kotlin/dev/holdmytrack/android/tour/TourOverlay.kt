package dev.holdmytrack.android.tour

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.graphics.RectF
import android.view.Choreographer
import android.view.Gravity
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.View
import android.widget.FrameLayout
import android.widget.TextView
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.isVisible
import dev.holdmytrack.android.R

/**
 * The tour drawn over the whole window (`apps/android/docs/SPEC.md` FR-2.12), in one of two looks:
 *
 * - **A step**: the screen dimmed but for a ring around the step's target, every touch taken so
 *   nothing under it changes, and the card across the top or bottom ([TourSteps.edge]).
 * - **A card** (a first-time card or the offer): no dim, under or over its target, touches
 *   outside it passing through to the map, the first of them closing it.
 *
 * The target is the union of the views [targets] returns, read every frame, since the sheet
 * slides, the Layers menu opens in a window of its own and the bottom bar switches tabs.
 * [onMissing] is called once if the target hasn't appeared within [MISSING_FRAMES] frames.
 */
@SuppressLint("ViewConstructor")
class TourOverlay(context: Context, private val dim: Boolean) : FrameLayout(context) {

    val card: View = LayoutInflater.from(context).inflate(R.layout.view_tour_card, this, false)
    val title: TextView = card.findViewById(R.id.tour_title)
    val progress: TextView = card.findViewById(R.id.tour_progress)
    val body: TextView = card.findViewById(R.id.tour_body)
    val skip: TextView = card.findViewById(R.id.tour_skip)
    val back: TextView = card.findViewById(R.id.tour_back)
    val next: TextView = card.findViewById(R.id.tour_next)

    /** Called on a press outside the card in the card look. */
    var onOutside: (() -> Unit)? = null

    private var targets: () -> List<View> = { emptyList() }
    private var onMissing: (() -> Unit)? = null
    private var hole: RectF? = null
    private var absent = 0
    private var tracking = false

    private val res = context.resources
    private val pad = res.getDimension(R.dimen.hmt_space_6)
    private val radius = res.getDimension(R.dimen.hmt_radius_lg)
    private val gap = res.getDimensionPixelSize(R.dimen.hmt_space_12)
    private val margin = res.getDimensionPixelSize(R.dimen.hmt_space_12)
    private val scrim = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = context.getColor(R.color.hmt_tour_scrim) }
    private val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = res.getDimension(R.dimen.hmt_space_2) * 1.5f
        color = context.getColor(R.color.hmt_accent)
    }
    private val path = Path()
    private val ringRect = RectF()

    init {
        setWillNotDraw(false)
        addView(card, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        // A step takes every touch; a card lets them through.
        isClickable = dim
        isFocusable = dim
    }

    /** Points at [targets], then follows them; call again for every step. */
    fun pointAt(targets: () -> List<View>, onMissing: (() -> Unit)?) {
        this.targets = targets
        this.onMissing = onMissing
        absent = 0
        hole = null
        card.visibility = View.INVISIBLE
        if (!tracking) {
            tracking = true
            Choreographer.getInstance().postFrameCallback(frame)
        }
    }

    private val frame = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            if (!tracking) return
            follow()
            Choreographer.getInstance().postFrameCallback(this)
        }
    }

    override fun onDetachedFromWindow() {
        tracking = false
        super.onDetachedFromWindow()
    }

    private fun follow() {
        val views = targets().filter { it.isAttachedToWindow && it.isShown && it.width > 0 && it.height > 0 }
        val wanted = targets().isNotEmpty()
        val next = if (views.isEmpty()) null else union(views)
        if (wanted && next == null) {
            if (++absent == MISSING_FRAMES) onMissing?.invoke()
            return
        }
        absent = 0
        if (next != hole) {
            hole = next
            place()
            invalidate()
        } else if (!card.isVisible) {
            place()
        }
    }

    /** The views' screen rects, as one rect in this view's coordinates. */
    private fun union(views: List<View>): RectF {
        val own = IntArray(2).also { getLocationOnScreen(it) }
        val box = Rect()
        val at = IntArray(2)
        views.forEachIndexed { i, view ->
            view.getLocationOnScreen(at)
            val r = Rect(at[0] - own[0], at[1] - own[1], at[0] - own[0] + view.width, at[1] - own[1] + view.height)
            if (i == 0) box.set(r) else box.union(r)
        }
        return RectF(box)
    }

    /** The card across the top or bottom for a step; under or over the target for a card. */
    private fun place() {
        if (height == 0 || card.height == 0) {
            post { place() }
            card.visibility = View.INVISIBLE
            return
        }
        val insets = ViewCompat.getRootWindowInsets(this)?.getInsets(WindowInsetsCompat.Type.systemBars())
        val top = (insets?.top ?: 0) + margin
        val bottom = (insets?.bottom ?: 0) + margin
        val target = hole
        val params = card.layoutParams as LayoutParams
        params.setMargins(margin, 0, margin, 0)
        if (dim) {
            val edge = TourSteps.edge(target?.top?.toInt(), card.height, top, gap)
            params.gravity = if (edge == TourSteps.Edge.TOP) Gravity.TOP else Gravity.BOTTOM
            params.topMargin = if (edge == TourSteps.Edge.TOP) top else 0
            params.bottomMargin = if (edge == TourSteps.Edge.BOTTOM) bottom else 0
        } else {
            params.gravity = Gravity.TOP
            params.topMargin = TourSteps.cardTop(target?.top?.toInt(), target?.bottom?.toInt(), card.height, height, top, gap)
        }
        card.layoutParams = params
        card.visibility = View.VISIBLE
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        if (!dim) return
        val target = hole
        path.reset()
        path.fillType = Path.FillType.EVEN_ODD
        path.addRect(0f, 0f, width.toFloat(), height.toFloat(), Path.Direction.CW)
        if (target != null) {
            ringRect.set(target.left - pad, target.top - pad, target.right + pad, target.bottom + pad)
            path.addRoundRect(ringRect, radius, radius, Path.Direction.CW)
            canvas.drawPath(path, scrim)
            canvas.drawRoundRect(ringRect, radius, radius, ring)
        } else {
            canvas.drawPath(path, scrim)
        }
    }

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        if (!dim && event.actionMasked == MotionEvent.ACTION_DOWN) {
            val r = Rect()
            card.getHitRect(r)
            if (!r.contains(event.x.toInt(), event.y.toInt())) {
                onOutside?.invoke()
                return false
            }
        }
        return super.dispatchTouchEvent(event)
    }

    private companion object {
        /** Frames a step's target gets to appear (a tab switch, the sheet opening) before it's skipped. */
        const val MISSING_FRAMES = 30
    }
}