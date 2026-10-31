package dev.holdmytrack.android.net

import org.junit.Assert.assertEquals
import org.junit.Test

/** Where the map's session check sends the user (`apps/android/docs/SPEC.md` FR-1.2). */
class SessionRouteTest {

    private fun route(
        signedIn: Boolean = true,
        verified: Boolean = true,
        emailVerified: Boolean = true,
        demo: Boolean = false,
        country: String = "DE",
    ) = SessionRoute.of(signedIn, verified, emailVerified, demo, country)

    @Test
    fun `a confirmed session with an email and a Country shows the map`() {
        assertEquals(SessionRoute.MAP, route())
    }

    @Test
    fun `no session goes to Sign in, whatever else is stored`() {
        assertEquals(SessionRoute.SIGN_IN, route(signedIn = false, verified = false, emailVerified = false, country = ""))
    }

    @Test
    fun `a restored token is checked before anything else is decided`() {
        assertEquals(SessionRoute.VERIFY, route(verified = false, emailVerified = false, country = ""))
    }

    @Test
    fun `an unconfirmed email goes to Verify before the first run`() {
        assertEquals(SessionRoute.VERIFY_EMAIL, route(emailVerified = false, country = ""))
    }

    @Test
    fun `no Country goes to the first run, except for the demo`() {
        assertEquals(SessionRoute.ONBOARDING, route(country = ""))
        assertEquals(SessionRoute.MAP, route(demo = true, country = ""))
    }
}