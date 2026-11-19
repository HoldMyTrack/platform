package dev.holdmytrack.android.map

/**
 * Where the editors along the bottom of the map sit, the Edit window and the Private location
 * editor: above the gesture bar, or above the keyboard while it's up. The keyboard covers the
 * window and never shrinks it (MainActivity), so the map keeps its size and the list its area.
 */
object EditorPlacement {
    /** The Edit window scrolls past this much of the screen, so the map keeps a band to edit on. */
    const val MAX_HEIGHT_FRACTION = 0.55f

    /** The least the Edit window scrolls within, about one field: the field being typed into
     *  stays in sight, even if the card then reaches under the edit bar (ChromeInsets.placeEditors). */
    const val MIN_SCROLL_DP = 96

    /** The editors' bottom margin: [space] above the gesture bar or the keyboard, whichever is
     *  taller. */
    fun bottom(space: Int, gesture: Int, keyboard: Int): Int = space + maxOf(gesture, keyboard)

    /** A card that can't scroll, the Private location editor: lifted to [bottom], or less when
     *  its [card] height would then reach above [top] (the top row's bottom), so its own top, and
     *  the name field there, stay on screen and the keyboard covers its buttons instead; never
     *  below [floor], clear of the gesture bar. [card] 0 is a card not laid out yet. */
    fun fitted(bottom: Int, floor: Int, screen: Int, card: Int, top: Int): Int =
        if (card == 0) bottom else minOf(bottom, screen - card - top).coerceAtLeast(floor)

    /** The Edit window's scroll cap: [MAX_HEIGHT_FRACTION] of [screen], or less when only [room]
     *  is left between the edit bar and the editors' bottom margin, the card's own [padding] taken
     *  off; never below [min]. */
    fun scrollCap(screen: Int, room: Int, padding: Int, min: Int): Int =
        minOf((screen * MAX_HEIGHT_FRACTION).toInt(), room - padding).coerceAtLeast(min)
}