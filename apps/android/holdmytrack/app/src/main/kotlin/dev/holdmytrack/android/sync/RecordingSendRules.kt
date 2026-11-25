package dev.holdmytrack.android.sync

import dev.holdmytrack.android.net.ApiException
import java.io.IOException

/**
 * What [RecordingSends] decides, as values (`apps/android/docs/SPEC.md` FR-5.2): a saved
 * recording is sent without a tick, since Save was the choice (ADR-0039).
 */
object RecordingSendRules {

    /** The demo account's recordings stay on the phone: the server refuses its uploads. */
    fun sends(signedIn: Boolean, emailVerified: Boolean, demo: Boolean): Boolean = signedIn && emailVerified && !demo

    /** Of the unsent recordings' [keys], those to send now: none on their way already, none swiped
     *  aside ([hidden]), none whose Delete is being asked about ([held]), and none the server refused this session unless the user asked again ([retry]), so a refusal isn't
     *  sent on every return to the app. */
    fun toSend(keys: List<String>, onItsWay: Set<String>, hidden: Set<String>, held: Set<String>, refused: Set<String>, retry: Boolean): List<String> =
        keys.filter { it !in onItsWay && it !in hidden && it !in held && (retry || it !in refused) }

    /** Whether Delete may remove the phone's copy: one sent lands whatever the phone keeps. */
    fun deletable(sending: Boolean, onItsWay: Boolean): Boolean = !sending && !onItsWay

    /** Of the unsent recordings' [keys], how many wait to be sent: none swiped aside. */
    fun unsent(keys: List<String>, hidden: Set<String>): Int = keys.count { it !in hidden }

    /** What a failed request means for the rest of the send. */
    enum class Failure {
        /** Nothing would go: the rest waits too. */
        STOP,

        /** This one waits; the rest goes on. */
        NEXT,

        /** The server won't take this one; the rest goes on. */
        REFUSE,
    }

    /** Only a failure every recording would meet stops the send, or one the server can't take
     *  would keep all those after it on the phone. */
    fun failure(e: Exception): Failure = when {
        e is ApiException -> when (e.code) {
            401, 403, 426, 429 -> Failure.STOP
            408 -> Failure.NEXT
            in 400..499 -> Failure.REFUSE
            else -> Failure.NEXT
        }
        // No answer came.
        e is IOException -> Failure.STOP
        // An answer the app can't read.
        else -> Failure.NEXT
    }

    /** The Sync sheet's line for the recordings not sent yet, with Retry: never for the demo
     *  account, whose recordings stay on the phone. */
    fun retryShown(demo: Boolean, unsent: Int): Boolean = !demo && unsent > 0

    /** What an unsent recording's row says. */
    sealed interface Note {
        data object Sending : Note

        /** Not sent yet: no connection, most likely; it goes on the next return to the app. */
        data object Waiting : Note

        data class Refused(val reason: String) : Note
    }

    /** Null for one swiped aside, which goes nowhere. */
    fun note(sending: Boolean, hidden: Boolean, refusedReason: String?): Note? = when {
        sending -> Note.Sending
        hidden -> null
        refusedReason != null -> Note.Refused(refusedReason)
        else -> Note.Waiting
    }
}
