package dev.holdmytrack.android

import org.junit.Assert.assertEquals
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
}