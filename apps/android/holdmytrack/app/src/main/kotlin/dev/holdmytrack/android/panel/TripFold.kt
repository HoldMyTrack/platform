package dev.holdmytrack.android.panel

/**
 * Folding the open Trip on the Trips tab (root `docs/SPEC.md` FR-13.6), the web's
 * `apps/web/src/ui/tripFold.ts` (`testdata/client-rules/trip-fold.json`): a tap on the open
 * Trip's folder hides or shows its description, statistics and rows and changes nothing else, so
 * it stays open with the map narrowed to it. A tap on another folder opens that one unfolded.
 */
object TripFold {
    /** [foldedId]: the Trip whose list is folded after the tap; [open]: the tapped Trip is
     *  another one, to open. */
    data class Click(val foldedId: String?, val open: Boolean)

    fun folderClick(foldedId: String?, openId: String?, clickedId: String): Click =
        if (clickedId != openId) Click(null, open = true) else Click(if (foldedId == clickedId) null else clickedId, open = false)

    /** Whether the open Trip's list is hidden; a fold left on another Trip counts for nothing. */
    fun isFolded(foldedId: String?, openId: String?): Boolean = openId != null && foldedId == openId
}
