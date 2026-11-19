package dev.holdmytrack.android.net

/**
 * What a failed request tells the user: the server's own wording for its refusal
 * ([ApiException]), or [of]'s fallback in the app's language for anything else, so a dropped
 * connection never shows "Unable to resolve host…" in English inside a translated screen.
 */
object FailureText {
    fun of(failure: Throwable, fallback: String): String =
        (failure as? ApiException)?.message?.takeIf { it.isNotBlank() } ?: fallback
}
