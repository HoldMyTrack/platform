package dev.holdmytrack.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** A forged `holdmytrack://oauth` can't end a sign-in in progress. */
class OAuthRedirectRuleTest {

    @Test
    fun `a code with a sign-in in flight is redeemed`() {
        assertEquals(OAuthRedirectRule.Exchange("abc"), OAuthRedirectRule.of("abc", null, hasVerifier = true))
    }

    @Test
    fun `an error is shown and leaves the sign-in waiting for its real redirect`() {
        assertEquals(OAuthRedirectRule.ShowError("facebook_no_email"), OAuthRedirectRule.of(null, "facebook_no_email", hasVerifier = true))
    }

    @Test
    fun `with no sign-in in flight a redirect is ignored`() {
        assertEquals(OAuthRedirectRule.Ignore, OAuthRedirectRule.of("abc", null, hasVerifier = false))
        assertEquals(OAuthRedirectRule.Ignore, OAuthRedirectRule.of(null, "x", hasVerifier = false))
    }

    @Test
    fun `the link opens the sign-in screen only for a round trip in flight`() {
        assertTrue(OAuthRedirectRule.forwards(signedIn = false, hasVerifier = true))
        assertFalse(OAuthRedirectRule.forwards(signedIn = false, hasVerifier = false))
    }

    @Test
    fun `a signed-in app is left as it is`() {
        assertFalse(OAuthRedirectRule.forwards(signedIn = true, hasVerifier = true))
    }

    @Test
    fun `a verifier is dropped once its tab has been abandoned`() {
        val saved = 1_000_000L
        assertTrue(BrowserHandoff.isFresh(saved, saved + BrowserHandoff.MAX_AGE_MS))
        assertFalse(BrowserHandoff.isFresh(saved, saved + BrowserHandoff.MAX_AGE_MS + 1))
        assertFalse(BrowserHandoff.isFresh(saved, saved - 1))
    }
}
