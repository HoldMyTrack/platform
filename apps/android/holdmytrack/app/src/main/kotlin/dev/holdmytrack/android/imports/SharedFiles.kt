package dev.holdmytrack.android.imports

import android.content.Intent

/**
 * Which files another app's intent hands the Upload screen: the one opened (`VIEW`) or those
 * shared (`SEND`, `SEND_MULTIPLE`), and only `content://` ones. Any app can start the screen with
 * them, so they are listed and wait for the user's Upload (ADR-0039), and a `file://` path, which
 * would let the sender name a file of this app's own, is dropped. Generic over the URI type so
 * the rule runs in a plain JVM test.
 */
object SharedFiles {

    fun <T> of(action: String?, opened: T?, shared: List<T>, scheme: (T) -> String?): List<T> {
        val all = when (action) {
            Intent.ACTION_VIEW -> listOfNotNull(opened)
            Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE -> shared
            else -> emptyList()
        }
        return all.filter { scheme(it).equals("content", ignoreCase = true) }
    }
}
