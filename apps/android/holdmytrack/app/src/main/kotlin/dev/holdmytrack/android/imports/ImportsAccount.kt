package dev.holdmytrack.android.imports

/** Whose upload queue it is ([FileImports]): files queued by one account are never sent or shown
 *  under another, a sign-out included. */
object ImportsAccount {

    /** Whether the queue filled by [owner] (null: nothing queued yet) stays with [current], the
     *  signed-in account's email, or null when no one is signed in. */
    fun keeps(owner: String?, current: String?): Boolean = owner == null || owner == current
}
