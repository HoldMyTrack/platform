package dev.holdmytrack.android.net

import java.io.InterruptedIOException
import java.net.SocketException
import java.net.UnknownHostException
import javax.net.ssl.SSLException

/**
 * What a failure tells the user, never an exception's own English text: the server's wording
 * for a refusal in the API's `{error, message}` shape, [of]'s `offline` for a connection that
 * failed, and `fallback` for anything else. A proxy's error page is an [ApiException] without an
 * [ApiException.errorCode], so it reads as `fallback` and not as raw HTML.
 */
object FailureText {
    fun of(failure: Throwable, fallback: String, offline: String = fallback): String {
        val refusal = failure as? ApiException
        if (refusal?.errorCode != null) refusal.message?.takeIf { it.isNotBlank() }?.let { return it }
        return if (isConnection(failure)) offline else fallback
    }

    /** No answer came: no DNS, no route, a reset or a timeout, here or in a cause. */
    private fun isConnection(failure: Throwable): Boolean =
        generateSequence(failure) { it.cause }.take(8).any {
            it is UnknownHostException || it is SocketException || it is InterruptedIOException || it is SSLException
        }
}
