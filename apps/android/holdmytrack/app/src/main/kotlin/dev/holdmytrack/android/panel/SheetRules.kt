package dev.holdmytrack.android.panel

/** Where the Tracks sheet rests after what the user does in it. */
object SheetRules {
    enum class Detent { COLLAPSED, HALF, EXPANDED }

    /** A row's tap: an open sheet comes down to half the map, so the focused track shows above
     *  it and the next row is still a tap away; a half or collapsed sheet stays where it is. */
    fun afterRowTap(detent: Detent): Detent = if (detent == Detent.EXPANDED) Detent.HALF else detent
}
