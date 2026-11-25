package dev.holdmytrack.android.panel

/**
 * How much of the Tracks sheet's content sits below the screen: the sheet keeps its open height
 * ([TracksPanel.setExpandedOffset]) wherever its top is, so without a bottom padding this tall
 * the lists' last rows and the Trips totals are off screen until the sheet is open.
 */
object SheetFit {
    /** The bottom padding for a sheet whose top is at [top], open at [expandedTop] and halfway at
     *  [halfTop]. Below halfway it stays the half's, so a collapsed sheet's lists keep their size
     *  and scroll position, covered rather than squeezed. */
    fun bottomPadding(top: Int, expandedTop: Int, halfTop: Int): Int =
        (minOf(top, halfTop) - expandedTop).coerceAtLeast(0)
}
