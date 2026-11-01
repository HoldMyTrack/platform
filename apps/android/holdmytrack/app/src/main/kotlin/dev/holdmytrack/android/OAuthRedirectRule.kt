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