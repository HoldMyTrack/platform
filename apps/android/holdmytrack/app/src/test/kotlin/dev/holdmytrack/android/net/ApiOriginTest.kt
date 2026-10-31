package dev.holdmytrack.android.net

import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Which requests get the session token (`HoldMyTrackApi`'s interceptors). */
class ApiOriginTest {

    private val api = "https://holdmytrack.app".toHttpUrl()

    private fun isApi(url: String, base: okhttp3.HttpUrl = api) = ApiOrigin.isApi(url.toHttpUrl(), base)

    @Test
    fun `the API's own requests are its own`() {
        assertTrue(isApi("https://holdmytrack.app/v1/auth/me"))
        assertTrue(isApi("https://holdmytrack.app/tiles/v1/fog-vector/3/4/5.pbf"))
        assertTrue(isApi("https://HOLDMYTRACK.app:443/v1/activities"))
    }

    @Test
    fun `a host that only starts like the API's is not`() {
        assertFalse(isApi("https://holdmytrack.app.evil.tld/v1/auth/me"))
        assertFalse(isApi("https://holdmytrack.app@evil.tld/v1/auth/me"))
        assertFalse(isApi("https://evil.tld/https://holdmytrack.app/v1"))
        assertFalse(isApi("https://api.maptiler.com/tiles/1/2/3.jpg"))
    }

    @Test
    fun `another scheme or port is not`() {
        assertFalse(isApi("http://holdmytrack.app/v1/auth/me"))
        assertFalse(isApi("https://holdmytrack.app:8443/v1/auth/me"))
    }

    @Test
    fun `a base with a path matches only at a segment boundary`() {
        val base = "http://10.0.2.2:8080/api".toHttpUrl()
        assertTrue(isApi("http://10.0.2.2:8080/api/v1/auth/me", base))
        assertTrue(isApi("http://10.0.2.2:8080/api", base))
        assertFalse(isApi("http://10.0.2.2:8080/apix/v1/auth/me", base))
    }
}