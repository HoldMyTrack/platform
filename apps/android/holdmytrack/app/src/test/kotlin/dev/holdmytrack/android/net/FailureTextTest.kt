package dev.holdmytrack.android.net

import java.io.IOException
import java.net.ConnectException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import kotlinx.serialization.SerializationException
import org.junit.Assert.assertEquals
import org.junit.Test

class FailureTextTest {
    private fun text(failure: Throwable) = FailureText.of(failure, fallback = "Something went wrong.", offline = "Network error")

    @Test
    fun theServersRefusalIsShownInItsOwnWords() {
        val refusal = ApiException.from(409, """{"error":"conflict","message":"Этот трек уже есть."}""")
        assertEquals("Этот трек уже есть.", text(refusal))
    }

    @Test
    fun aProxysErrorPageIsNotShown() {
        assertEquals("Something went wrong.", text(ApiException.from(502, "<html><body>502 Bad Gateway</body></html>")))
        assertEquals("Something went wrong.", text(ApiException(502, "")))
    }

    @Test
    fun aFailedConnectionReadsAsOffline() {
        assertEquals("Network error", text(UnknownHostException("Unable to resolve host \"api.holdmytrack.dev\"")))
        assertEquals("Network error", text(ConnectException("Failed to connect")))
        assertEquals("Network error", text(SocketTimeoutException("timeout")))
        assertEquals("Network error", text(IOException("upload failed", SocketTimeoutException("timeout"))))
    }

    @Test
    fun anyOtherFailureReadsAsTheFallback() {
        assertEquals("Something went wrong.", text(IOException("not an image")))
        assertEquals("Something went wrong.", text(SerializationException("Unexpected JSON token")))
        assertEquals("Something went wrong.", text(IllegalStateException("boom")))
    }

    @Test
    fun withoutAnOfflineTextEveryFailureReadsAsTheFallback() {
        assertEquals("Could not save the trip", FailureText.of(UnknownHostException("x"), "Could not save the trip"))
    }
}
