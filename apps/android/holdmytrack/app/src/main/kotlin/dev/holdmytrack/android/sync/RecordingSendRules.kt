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
     *  aside ([hidden]), none whose Delete is being asked about ([held]), and none the server
     *  refused this session unless the user asked again ([retry]), so a refusal isn't sent on every
     *  return to the app. Those that got no answer ([unanswered], the latest last) go last in that
     *  order, or two of them would stop every send before the rest. */
    fun toSend(
        keys: List<String>,
        onItsWay: Set<String>,
        hidden: Set<String>,
        held: Set<String>,
        refused: Set<String>,
        unanswered: List<String>,
        retry: Boolean,
    ): List<String> {
        val going = keys.filter { it !in onItsWay && it !in hidden && it !in held && (retry || it !in refused) }
        return going.filter { it !in unanswered } + unanswered.filter { it in going }
    }

    /** What Delete does with a recording, as the phone has it when the question is answered. */
    enum class Deletion {
        DELETED,

        /** Being sent or on its way: it lands whatever the phone keeps. */
        SENDING,

        /** Off the phone already: it landed. */
        LANDED,
    }

    fun deletion(stored: Boolean, going: Boolean): Deletion = when {
        going -> Deletion.SENDING
        stored -> Deletion.DELETED
        else -> Deletion.LANDED
    }

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

    /** Whether [e] says nothing from the server: the recording's fault, too long to upload or to
     *  handle, or the connection's. */
    fun unanswered(e: Exception): Boolean = if (e is ApiException) e.code in setOf(408, 502, 504) else e is IOException

    /** Only a failure every recording would meet stops the send, or one the server can't take
     *  would keep all those after it on the phone; only an answer about the recording itself
     *  refuses it. Two in a row with no answer ([afterUnanswered]) say it's the connection. */
    fun failure(e: Exception, afterUnanswered: Boolean): Failure = when {
        unanswered(e) -> if (afterUnanswered) Failure.STOP else Failure.NEXT
        e is ApiException -> when (e.code) {
            400, 413, 422 -> Failure.REFUSE
            500 -> Failure.NEXT
            else -> Failure.STOP
        }
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
