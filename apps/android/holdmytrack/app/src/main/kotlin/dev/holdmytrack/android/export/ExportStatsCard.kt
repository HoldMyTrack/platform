package dev.holdmytrack.android.export

import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper

/**
 * The stats card the server draws for the viewfinder's current [ExportStatsRules.Request]: asked
 * for again after a pause in changing it, and held until the next one arrives, so Capture draws
 * the card the window previews and never asks a second time. The web's `useStatsCard`.
 */
class ExportStatsCard(
    /** `HoldMyTrackApi.statsCard`, for the request; null when every activity is Pending. */
    private val fetch: (ExportStatsRules.Request, (Result<Bitmap?>) -> Unit) -> Unit,
    /** The card, [ready] or [error] changed. */
    private val onChange: () -> Unit,
) {
    private val main = Handler(Looper.getMainLooper())
    private var wanted: ExportStatsRules.Request? = null
    private var pending: Runnable? = null
    /** The request the last answer was for: a card, no card or an error alike. */
    private var settled: String? = null

    /** The card last drawn; null with none to show. */
    var card: Bitmap? = null
        private set
    var error: String? = null
        private set

    /** Whether [card] answers the current request, so Capture would draw what's previewed. */
    val ready: Boolean get() = wanted?.let { it.key == settled } ?: true

    /** Asks for [request]'s card after the pause, or drops the card for null. */
    fun want(request: ExportStatsRules.Request?) {
        if (request?.key == wanted?.key) return
        wanted = request
        pending?.let(main::removeCallbacks)
        pending = null
        if (request == null) {
            card = null
            error = null
            onChange()
            return
        }
        onChange()
        val ask = Runnable {
            pending = null
            fetch(request) { result ->
                // An answer for a request no longer wanted is dropped.
                if (wanted?.key != request.key) return@fetch
                card = result.getOrNull()
                error = result.exceptionOrNull()?.let { it.message?.takeIf(String::isNotBlank) ?: it.javaClass.simpleName }
                settled = request.key
                onChange()
            }
        }
        pending = ask
        main.postDelayed(ask, DELAY_MS)
    }

    /** The viewfinder closed: nothing is asked for or held. */
    fun clear() {
        pending?.let(main::removeCallbacks)
        pending = null
        wanted = null
        settled = null
        card = null
        error = null
    }

    private companion object {
        /** How long the request waits after the size or the checked set last changed. */
        const val DELAY_MS = 400L
    }
}