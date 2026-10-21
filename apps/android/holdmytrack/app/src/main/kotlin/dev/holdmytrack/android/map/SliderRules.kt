package dev.holdmytrack.android.map

/**
 * The date-range slider's rules (root `docs/SPEC.md` FR-6), as plain values: how many activity
 * days fit, where a date's knob sits, what a knob move or a pan does to the selection, and how the
 * window follows a range. The web's `apps/web/src/ui/sliderRules.ts`; both run
 * `testdata/client-rules`.
 *
 * Days are the window's activity days (`YYYY-MM-DD`, ascending). Boundary b is where slot b begins
 * (0..n). A date before the window is -1 and one after it n + 1, off-screen, unless there's no
 * history on that side, where it sits on the edge: today with nothing recorded yet still has its
 * end knob on the right edge.
 */
object SliderRules {

    /** « »'s width, its gap to the track, and the track's inset each side, in dp. */
    private const val PAGE = 22
    private const val GAP = 6
    private const val PAD = 8

    /** The narrowest activity day: two knobs a day apart stay apart. */
    private const val MIN_SLOT = 18
    const val MIN_DAYS = 7
    const val MAX_DAYS = 31

    /** « » show only if the track still holds this many days beside them. */
    private const val BUTTONS_FROM = 12

    data class Layout(val buttons: Boolean, val days: Int)

    /** How many activity days the window holds at [width] dp (the room for « track »), and
     *  whether « » show: always for a fine pointer, which has no swipe; otherwise only where they
     *  leave enough track. */
    fun layout(width: Int, finePointer: Boolean): Layout {
        val withButtons = width - 2 * (PAGE + GAP) - 2 * PAD
        val buttons = finePointer || Math.floorDiv(withButtons, MIN_SLOT) >= BUTTONS_FROM
        val track = if (buttons) withButtons else width - 2 * PAD
        return Layout(buttons, Math.floorDiv(track, MIN_SLOT).coerceIn(MIN_DAYS, MAX_DAYS))
    }

    /** The window: its days and whether there's history beyond either end. */
    data class Window(val days: List<String>, val canPanEarlier: Boolean, val canPanLater: Boolean)

    data class Boundaries(val start: Int, val end: Int)

    /** The boundaries of [range]'s two knobs: start where its first day begins, end where its
     *  last one ends. */
    fun boundaries(window: Window, range: DateRange): Boundaries {
        val days = window.days
        val n = days.size
        val first = days.firstOrNull() ?: return Boundaries(0, 0)
        val last = days.last()
        val start = if (range.from < first) {
            if (window.canPanEarlier) -1 else 0
        } else {
            val i = days.indexOfFirst { it >= range.from }
            if (i == -1) (if (window.canPanLater) n + 1 else n) else i
        }
        val end = when {
            range.to > last -> if (window.canPanLater) n + 1 else n
            range.to < first -> if (window.canPanEarlier) -1 else 0
            else -> days.count { it <= range.to }
        }
        return Boundaries(start, end)
    }

    enum class Knob { START, END }

    /** One knob moved to boundary [b], a slot from the other (pushing it if needed). A knob that
     *  ends up where it already was keeps its own date, which may lie off-screen or in a gap
     *  between activity days; only a knob that moved takes a slot's date. */
    fun moveKnob(window: Window, range: DateRange, knob: Knob, b: Int): DateRange {
        val days = window.days
        val n = days.size
        if (n == 0) return range
        val (s0, e0) = boundaries(window, range)
        var s = s0
        var e = e0
        if (knob == Knob.START) {
            s = b.coerceIn(0, n - 1)
            e = maxOf(e0, s + 1)
        } else {
            e = b.coerceIn(1, n)
            s = minOf(s0, e - 1)
        }
        return DateRange(from = if (s == s0) range.from else days[s], to = if (e == e0) range.to else days[e - 1])
    }

    /** A tick on [boundary]: tall where a month starts ([monthStart]), and the month (1..12)
     *  labelled from it — each month start, and the first month in view at the left edge. */
    data class Tick(val boundary: Int, val monthStart: Boolean, val month: Int?)

    /** A tick on every boundary 0..n; the outer two are plain. */
    fun ticks(days: List<String>): List<Tick> {
        if (days.isEmpty()) return emptyList()
        fun month(date: String) = date.substring(5, 7).toInt()
        return (0..days.size).map { b ->
            val before = days.getOrNull(b - 1)
            val after = days.getOrNull(b)
            when {
                before == null -> Tick(b, false, month(after!!))
                after == null || before.take(7) == after.take(7) -> Tick(b, false, null)
                else -> Tick(b, true, month(after))
            }
        }
    }

    /** A pan has landed on the window [days]: the knobs it was carrying ([start], [end]) move onto
     *  the new edges, the other one pushed if they'd cross. */
    fun panLand(days: List<String>, range: DateRange, start: Boolean, end: Boolean): DateRange {
        val first = days.firstOrNull() ?: return range
        val last = days.last()
        var next = range
        if (start) next = DateRange(first, if (next.to < first) first else next.to)
        if (end) next = DateRange(if (next.from > last) last else next.from, last)
        return next
    }

    /** Where a window of [windowDays] over [count] loaded days, now from [left], moves to show
     *  the days [first]..[last] (indices): as little as it takes; for a run longer than the
     *  window, its edge on the [dir] side (-1 the start, 1 the end). */
    fun windowFit(count: Int, windowDays: Int, left: Int, first: Int, last: Int, dir: Int): Int {
        val maxStart = maxOf(0, count - windowDays)
        val next = when {
            last - first + 1 > windowDays -> if (dir < 0) first else last - windowDays + 1
            first < left -> first
            last >= left + windowDays -> last - windowDays + 1
            else -> left
        }
        return next.coerceIn(0, maxStart)
    }
}
