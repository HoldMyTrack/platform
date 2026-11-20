package dev.holdmytrack.android.photos

/**
 * When [PhotosController.refresh] reads the scope's photos again. A forced refresh (a Photos tab
 * save, a reprocess, a Trip's members) that comes while the map has no view is owed, and the first
 * refresh with a view then reads, even for the same scope.
 */
object PhotoRefresh {

    /** Whether a refresh is owed after one that came with no view. */
    fun owedWithoutView(force: Boolean, owed: Boolean): Boolean = owed || force

    /** Whether a refresh with a view reads the photos for [next] again, [scope] being what's loaded. */
    fun fetches(next: String?, scope: String?, force: Boolean, owed: Boolean): Boolean = next != scope || force || owed

    /** Whether photos fetched for the single track [startedFor] go to an Edit window showing
     *  [nowShowing]: the same track, though the window may be another, built since. */
    fun deliversTo(startedFor: String?, nowShowing: String?): Boolean = startedFor != null && startedFor == nowShowing
}
