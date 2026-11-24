package dev.holdmytrack.android.map

/**
 * Where the editors along the bottom of the map sit, the Edit window and the Private location
 * editor: sheets flush with the screen's bottom that ride on the keyboard while it's up. The
 * keyboard covers the window and never shrinks it (MainActivity), so the map keeps its size and
 * the list its area.
 */
object EditorPlacement {
    /** An editor takes no more than this much of the screen, so the map keeps a band to
     *  edit on; past it, its fields scroll under the header. */
    const val MAX_HEIGHT_FRACTION = 0.55f

    /** The least an editor's fields scroll within, about one field: the field being typed
     *  into stays in sight, even if the sheet then reaches under the top row. */
    const val MIN_SCROLL_DP = 96

    /** A sheet's bottom margin and bottom padding ([sheet]). */
    data class Sheet(val margin: Int, val padding: Int)

    /** While the [keyboard] is up the sheet rides on it, a margin that tall and no padding;
     *  otherwise it reaches the screen's edge, its padding as tall as the [gesture] bar. */
    fun sheet(gesture: Int, keyboard: Int): Sheet = if (keyboard > 0) Sheet(keyboard, 0) else Sheet(0, gesture)

    /** An editor's scroll cap: the sheet within [MAX_HEIGHT_FRACTION] of [screen], or within
     *  the [room] left between the top row and its bottom margin, less its [chrome] (the header
     *  and paddings around the fields); never below [min]. */
    fun scrollCap(screen: Int, room: Int, chrome: Int, min: Int): Int =
        (minOf((screen * MAX_HEIGHT_FRACTION).toInt(), room) - chrome).coerceAtLeast(min)
}