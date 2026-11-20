package dev.holdmytrack.android

import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.GetCredentialException
import androidx.credentials.exceptions.NoCredentialException

/**
 * What Sign in with Google's picker failing means for the screen, by Credential Manager's
 * exception: the user closed it, it offered no account, or anything else.
 */
enum class GoogleFailure {
    /** Closed by the user: nothing to say. */
    CANCELLED,

    /** No account to offer. Usually none on the phone; in development, also a missing Android
     *  OAuth client for the signing key (`apps/android/docs/IMPLEMENTATION.md` §2.3). */
    NO_ACCOUNT,

    /** Any other failure, worth trying again. */
    FAILED;

    companion object {
        fun of(e: GetCredentialException): GoogleFailure = when (e) {
            is GetCredentialCancellationException -> CANCELLED
            is NoCredentialException -> NO_ACCOUNT
            else -> FAILED
        }
    }
}
