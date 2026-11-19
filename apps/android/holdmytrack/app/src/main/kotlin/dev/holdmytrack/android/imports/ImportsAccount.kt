package dev.holdmytrack.android.imports

/** Whose upload queue it is ([FileImports]): files queued by one account are never sent or shown
 *  under another, a sign-out included. */
object ImportsAccount {

    /** Whether the queue filled by [owner] (null: nothing queued yet) stays with [current], the
     *  signed-in account's email, or null when no one is signed in. */
    fun keeps(owner: String?, current: String?): Boolean = owner == null || owner == current

    /** Whether a file sent for [sentFor] still reports to the queue, [owner] being its owner as
     *  the send ends: not once the session it went for has ended, nor to the next account's. */
    fun reports(sentFor: String?, owner: String?): Boolean = sentFor != null && sentFor == owner
}
