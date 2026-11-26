package dev.holdmytrack.android.sync

import dev.holdmytrack.android.net.ApiException
import java.io.IOException
import java.time.Instant

/**
 * What [RecordingSends] decides, as values (`apps/docs/SPEC.md` FR-5.2): a saved
 * recording is sent without a tick, since Save was the choice (ADR-0039). The cases are
 * `testdata/client-rules/recording-send-*.json`, which iOS's `RecordingSends` runs too.
 */
object RecordingSendRules {

    /** The demo account's recordings stay on the phone: the server refuses its uploads. */
    fun sends(signedIn: Boolean, emailVerified: Boolean, demo: Boolean): Boolean = signedIn && emailVerified && !demo

    /** A recording not marked sent in the store: its [Candidate.key] and start. */
    data class Unsent(val key: String, val startedAt: Instant)

    /** Of the [unsent] recordings, the keys to send now, newest first: none on their way already, none swiped
     *  aside ([hidden]), none whose Delete is being asked about ([held]), and none the server
     *  refused this session unless the user asked again ([retry]), so a refusal isn't sent on every
     *  return to the app. Those whose last request failed ([setBack], the latest last) go last
     *  in that order, or one that stops every send would keep the rest on the phone. */
    fun toSend(
        unsent: List<Unsent>,
        onItsWay: Set<String>,
        hidden: Set<String>,
        held: Set<String>,
        refused: Set<String>,
        setBack: List<String>,
        retry: Boolean,
    ): List<String> {
        val going = unsent.sortedByDescending { it.startedAt }.map { it.key }.filter { it !in onItsWay && it !in hidden && it !in held && (retry || it !in refused) }
        return going.filter { it !in setBack } + setBack.filter { it in going }
    }

    /** What Delete does with a recording, as the phone has it when the question is answered. */
    enum class Deletion {
        DELETED,

        /** Being sent or on its way: it lands whatever the phone keeps. */
        SENDING,

        /** Off the phone already, on the map. */
        LANDED,
    }

    /** [landed], whether the app saw it land: a missing copy may be one deleted already. */
    fun deletion(stored: Boolean, going: Boolean, landed: Boolean): Deletion = when {
        going -> Deletion.SENDING
        !stored && landed -> Deletion.LANDED
        else -> Deletion.DELETED
    }

    /** Of the unsent recordings' [keys], how many wait to be sent: none swiped aside, and none of
     *  the demo account's. Library's badge and the Sync sheet's Retry line count them. */
    fun waiting(keys: List<String>, hidden: Set<String>, demo: Boolean): Int = if (demo) 0 else keys.count { it !in hidden }

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

    /** What a recording's row says. */
    sealed interface Note {
        /** Taken by the server, on its way to the map. */
        data object Processing : Note

        data object Sending : Note

        /** Not sent yet: no connection, most likely; it goes on the next return to the app. */
        data object Waiting : Note

        data class Refused(val reason: String) : Note
    }

    /** Null for one that goes nowhere: the demo account's, or one swiped aside. */
    fun note(sent: Boolean, sending: Boolean, hidden: Boolean, refusedReason: String?, demo: Boolean): Note? = when {
        demo -> null
        sent -> Note.Processing
        sending -> Note.Sending
        hidden -> null
        refusedReason != null -> Note.Refused(refusedReason)
        else -> Note.Waiting
    }
}
