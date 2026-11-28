package dev.holdmytrack.android

/** What Sign in does with its two fields (`apps/docs/SPEC.md` FR-1.1): the app says only that
 *  one is missing; every other rule is the server's, so the two never disagree. */
sealed interface SignInFields {
    /** Send them: the email trimmed, the password as typed. */
    data class Submit(val email: String, val password: String) : SignInFields

    /** The email is blank or the password empty. */
    data object Missing : SignInFields

    companion object {
        /** Unicode's White_Space, as iOS trims it: Kotlin's [Char.isWhitespace] also counts the
         *  separators U+001C–U+001F and misses U+0085. */
        private fun isWhiteSpace(c: Char): Boolean = c == '\u0085' || (c.isWhitespace() && c !in '\u001c'..'\u001f')

        fun of(email: String, password: String): SignInFields {
            val address = email.trim(::isWhiteSpace)
            return if (address.isEmpty() || password.isEmpty()) Missing else Submit(address, password)
        }
    }
}
