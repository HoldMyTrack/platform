package dev.holdmytrack.android.net

import java.io.IOException
import java.net.UnknownHostException
import kotlinx.serialization.SerializationException
import org.junit.Assert.assertEquals
import org.junit.Test

class FailureTextTest {
    @Test
    fun theServersRefusalIsShownInItsOwnWords() {
        val refusal = ApiException.from(409, """{"error":"conflict","message":"Этот трек уже есть."}""")
        assertEquals("Этот трек уже есть.", FailureText.of(refusal, "Network error"))
    }

    @Test
    fun aDroppedConnectionReadsTheAppsOwnWording() {
        val dropped = UnknownHostException("Unable to resolve host \"api.holdmytrack.dev\"")
        assertEquals("Network error", FailureText.of(dropped, "Network error"))
    }

    @Test
    fun anyOtherFailureReadsTheAppsOwnWording() {
        assertEquals("Network error", FailureText.of(IOException("not an image"), "Network error"))
        assertEquals("Network error", FailureText.of(SerializationException("Unexpected JSON token"), "Network error"))
        assertEquals("Network error", FailureText.of(IllegalStateException("boom"), "Network error"))
    }
}
