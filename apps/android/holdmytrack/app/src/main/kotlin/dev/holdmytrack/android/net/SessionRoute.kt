package dev.holdmytrack.android.net

/** Where the map's session check sends the user ([SessionGate]), as a value. */
enum class SessionRoute {
    /** No session: Sign in. */
    SIGN_IN,

    /** A token restored from disk the server hasn't confirmed yet: check it first. */
    VERIFY,

    /** The email isn't confirmed: every tile and sync request would be a `403`. */
    VERIFY_EMAIL,

    /** The first run, as on the web: no Country yet, which decides the units. */
    ONBOARDING,

    /** The map may show the user's layers. */
    MAP;

    companion object {
        fun of(signedIn: Boolean, verified: Boolean, emailVerified: Boolean, demo: Boolean, country: String): SessionRoute = when {
            !signedIn -> SIGN_IN
            !verified -> VERIFY
            !emailVerified -> VERIFY_EMAIL
            !demo && country.isEmpty() -> ONBOARDING
            else -> MAP
        }
    }
}