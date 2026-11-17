package dev.holdmytrack.android

import org.junit.Assert.assertEquals
import org.junit.Test

class BrowserFailureTest {

    @Test
    fun `a sign-up tab's error is a sign-up failure whatever its code`() {
        assertEquals(BrowserFailure.SIGN_UP, BrowserFailure.of(BrowserFlow.SIGN_UP, null))
        assertEquals(BrowserFailure.SIGN_UP, BrowserFailure.of(BrowserFlow.SIGN_UP, "facebook_no_email"))
    }

    @Test
    fun `a Facebook tab's codes keep their meaning`() {
        assertEquals(BrowserFailure.FACEBOOK_NO_EMAIL, BrowserFailure.of(BrowserFlow.FACEBOOK, "facebook_no_email"))
        assertEquals(BrowserFailure.FACEBOOK_EMAIL_IN_USE, BrowserFailure.of(BrowserFlow.FACEBOOK, "facebook_email_in_use"))
        assertEquals(BrowserFailure.GOOGLE, BrowserFailure.of(BrowserFlow.FACEBOOK, "google"))
        assertEquals(BrowserFailure.FACEBOOK, BrowserFailure.of(BrowserFlow.FACEBOOK, "x"))
    }

    @Test
    fun `a tab with no flow kept is treated as Facebook's`() {
        assertEquals(BrowserFailure.FACEBOOK, BrowserFailure.of(null, null))
    }
}
