package dev.holdmytrack.android.panel

/** What a Trips list answer means on the Trips tab (`testdata/client-rules/trip-list-answer.json`). */
object TripsList {
    /** On a return ([quiet]), an [open] Trip missing from [listed] was deleted elsewhere. */
    fun openGone(quiet: Boolean, open: String?, listed: Set<String>, failed: Boolean): Boolean =
        !failed && quiet && open != null && open !in listed

    /** A failed read says so when nothing is shown yet, or when the tab asked itself. */
    fun showsError(quiet: Boolean, ready: Boolean, failed: Boolean): Boolean = failed && (!quiet || !ready)
}
