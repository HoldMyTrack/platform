package dev.holdmytrack.android

import android.content.Context
import androidx.core.content.edit

/**
 * The verifier of a browser round trip in flight ([SignInActivity.openBrowserRoundTrip]) and the
 * flow that opened the tab, kept on disk since the process can be killed while the tab is in
 * front. A verifier older than [MAX_AGE_MS] is a tab the user abandoned and reads as none.
 */
object BrowserHandoff {

    /** Past the server's own windows (10 minutes on the provider, 2 to redeem the code), with
     *  room for a sign-up form filled in slowly. */
    const val MAX_AGE_MS = 60 * 60_000L

    class Pending(val verifier: String, val flow: BrowserFlow?)

    fun save(context: Context, verifier: String, flow: BrowserFlow, now: Long) = prefs(context).edit {
        putString(KEY_VERIFIER, verifier)
        putString(KEY_FLOW, flow.name)
        putLong(KEY_SAVED_AT, now)
    }

    /** The round trip in flight, or null when none is, or it was abandoned (then forgotten). */
    fun pending(context: Context, now: Long): Pending? {
        val prefs = prefs(context)
        val verifier = prefs.getString(KEY_VERIFIER, null) ?: return null
        if (!isFresh(prefs.getLong(KEY_SAVED_AT, 0), now)) {
            clear(context)
            return null
        }
        val flow = prefs.getString(KEY_FLOW, null)?.let { name -> BrowserFlow.entries.firstOrNull { it.name == name } }
        return Pending(verifier, flow)
    }

    fun clear(context: Context) = prefs(context).edit { clear() }

    fun isFresh(savedAt: Long, now: Long): Boolean = now - savedAt in 0..MAX_AGE_MS

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private const val PREFS = "sign_in_handoff"
    private const val KEY_VERIFIER = "verifier"
    private const val KEY_FLOW = "flow"
    private const val KEY_SAVED_AT = "saved_at"
}
