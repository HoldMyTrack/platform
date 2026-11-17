package dev.holdmytrack.android

/** What the "check your email" screen's Confirm does with what's typed in its code field. */
sealed interface VerifyAction {
    /** Send the code; the server judges it, as it judges sign-in's fields. */
    data class Submit(val code: String) : VerifyAction

    /** Nothing typed: ask whether the address was confirmed some other way, by the email's link. */
    data object Check : VerifyAction

    companion object {
        fun of(typed: String): VerifyAction = typed.trim().let { if (it.isEmpty()) Check else Submit(it) }
    }
}
