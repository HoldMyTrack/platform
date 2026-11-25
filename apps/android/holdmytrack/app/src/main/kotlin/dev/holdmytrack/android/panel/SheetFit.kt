package dev.holdmytrack.android.panel

/**
 * How much of the Tracks sheet's content sits below the screen: the sheet keeps its open height
 * ([TracksPanel.setExpandedOffset]) wherever its top is, so without a bottom padding this tall
 * the lists' last rows and the Trips totals are off screen until the sheet is open.
 */
object SheetFit {
    /** The bottom padding for a sheet whose top is at [top], open at [expandedTop] and halfway at
     *  [halfTop]. Below halfway it stays the half's, so a collapsed sheet's lists keep their size
     *  and scroll position, covered rather than squeezed. While the sheet is [moving] it keeps
     *  [current]: a padding that changes lays the whole sheet out again, which no frame of a slide
     *  has time for. */
    fun bottomPadding(top: Int, expandedTop: Int, halfTop: Int, current: Int, moving: Boolean): Int =
        if (moving) current else (minOf(top, halfTop) - expandedTop).coerceAtLeast(0)
}
