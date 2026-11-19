package dev.holdmytrack.android.net

import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Update screen's trigger and target (`apps/android/docs/SPEC.md` FR-1.8). */
class AppBuildTest {

    private val api = "https://holdmytrack.com".toHttpUrl()

    private fun refused(url: String, code: Int = 426) = AppBuild.isRefusal(url.toHttpUrl(), api, code)

    @Test
    fun `a 426 from the API's own v2 is the server turning this build away`() {
        assertTrue(refused("https://holdmytrack.com/v2/auth/me"))
    }

    @Test
    fun `anything else is not`() {
        assertFalse(refused("https://holdmytrack.com/v2/auth/me", 401))
        assertFalse(refused("https://holdmytrack.com/tiles/v1/fog-vector/3/4/5.pbf"))
        assertFalse(refused("https://api.maptiler.com/v1/tiles"))
    }

    @Test
    fun `a host that only starts like the API's is not it`() {
        assertFalse(refused("https://holdmytrack.com.evil.tld/v2/auth/me"))
        assertFalse(refused("https://holdmytrack.com@evil.tld/v2/auth/me"))
    }

    @Test
    fun `Update leads to the app's Play listing`() {
        assertEquals(
            "https://play.google.com/store/apps/details?id=dev.holdmytrack.android",
            AppBuild.updateLink("dev.holdmytrack.android"),
        )
    }

    @Test
    fun `the User-Agent carries the versionCode the server compares`() {
        assertEquals("HoldMyTrack-Android/1.2.3 (62da50b; 812)", AppBuild.userAgent("1.2.3", "62da50b", 812))
    }
}
