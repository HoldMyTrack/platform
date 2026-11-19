package dev.holdmytrack.android.net

import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertEquals
import org.junit.Test

/** An id stays one path segment of the request it is put in. */
class ApiPathTest {

    private val base = "https://holdmytrack.com".toHttpUrl()

    @Test
    fun `segments follow v2`() {
        assertEquals("https://holdmytrack.com/v2/trips/t1/send", ApiPath.v2(base, "trips", "t1", "send").toString())
    }

    @Test
    fun `an id can't change the path, query or fragment`() {
        val url = ApiPath.v2(base, "tracks", "../account?x=1#y")
        assertEquals(listOf("v2", "tracks", "../account?x=1#y"), url.pathSegments)
        assertEquals(null, url.query)
        assertEquals(null, url.fragment)
    }

    @Test
    fun `a base with a path keeps it`() {
        assertEquals("http://10.0.2.2:8100/api/v2/spots", ApiPath.v2("http://10.0.2.2:8100/api".toHttpUrl(), "spots").toString())
    }
}
