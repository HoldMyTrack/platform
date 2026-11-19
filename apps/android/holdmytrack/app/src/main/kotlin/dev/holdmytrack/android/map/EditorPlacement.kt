package dev.holdmytrack.android.map

/**
 * Where the editors along the bottom of the map sit, the Edit window and the Private location
 * editor: above the gesture bar, or above the keyboard while it's up. The keyboard covers the
 * window and never shrinks it (MainActivity), so the map keeps its size and the list its area.
 */
object EditorPlacement {
    /** The Edit window scrolls past this much of the screen, so the map keeps a band to edit on. */
    const val MAX_HEIGHT_FRACTION = 0.55f

    /** The editors' bottom margin: [space] above the gesture bar or the keyboard, whichever is
     *  taller. */
    fun bottom(space: Int, gesture: Int, keyboard: Int): Int = space + maxOf(gesture, keyboard)

    /** The Edit window's scroll cap: [MAX_HEIGHT_FRACTION] of [screen], or less when only [room]
     *  is left between the edit bar and the editors' bottom margin, the card's own [padding] taken
     *  off; never below 0. */
    fun scrollCap(screen: Int, room: Int, padding: Int): Int =
        minOf((screen * MAX_HEIGHT_FRACTION).toInt(), room - padding).coerceAtLeast(0)
}