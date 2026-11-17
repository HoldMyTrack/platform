package dev.holdmytrack.android.map

import android.content.Context
import android.content.SharedPreferences
import androidx.core.content.edit

/** Whether this phone's [account] closed the empty map notice, which then stays down for it. */
class EmptyNoticeDismissal(context: Context, account: String) {

    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private val key = "empty_notice_closed.$account"

    fun closed(): Boolean = prefs.getBoolean(key, false)

    fun close() {
        prefs.edit { putBoolean(key, true) }
    }

    fun clear() {
        prefs.edit { remove(key) }
    }

    private companion object {
        const val PREFS_NAME = "holdmytrack.map"
    }
}
