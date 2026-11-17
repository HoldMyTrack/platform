package dev.holdmytrack.android

/**
 * What a `holdmytrack://oauth` redirect means for a sign-in, as a value. Any app can fire that
 * link, and the server's redirect carries no state to tell a real one by, so a forged one must
 * not be able to end a sign-in in progress.
 */
sealed interface OAuthRedirectRule {
    /** Redeem [code] with the stored verifier, which is then used up. */
    data class Exchange(val code: String) : OAuthRedirectRule

    /** Show the server's [error] code; the verifier stays for the real redirect still to come. */
    data class ShowError(val error: String?) : OAuthRedirectRule

    /** No browser sign-in is in flight: nothing to act on. */
    data object Ignore : OAuthRedirectRule

    companion object {
        fun of(code: String?, error: String?, hasVerifier: Boolean): OAuthRedirectRule = when {
            !hasVerifier -> Ignore
            code != null -> Exchange(code)
            else -> ShowError(error)
        }
    }
}
/** Which page a browser-tab round trip started on, kept with its verifier. */
enum class BrowserFlow { SIGN_UP, FACEBOOK }

/** What a browser round trip's `?error=` code tells the user: the two Facebook refusals a person
 *  can act on, else that the flow that opened the tab failed. The sign-up page shows its own
 *  refusals, so an error reaching the app from it is a generic one. */
enum class BrowserFailure {
    FACEBOOK_NO_EMAIL, FACEBOOK_EMAIL_IN_USE, GOOGLE, FACEBOOK, SIGN_UP;

    companion object {
        fun of(flow: BrowserFlow?, code: String?): BrowserFailure = when {
            flow == BrowserFlow.SIGN_UP -> SIGN_UP
            code == "facebook_no_email" -> FACEBOOK_NO_EMAIL
            code == "facebook_email_in_use" -> FACEBOOK_EMAIL_IN_USE
            code == "google" -> GOOGLE
            else -> FACEBOOK
        }
    }
}
