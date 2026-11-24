package dev.holdmytrack.android.sync

/**
 * What [RecordingSends] decides, as values (`apps/android/docs/SPEC.md` FR-5.2): a saved
 * recording is sent without a tick, since Save was the choice (ADR-0039).
 */
object RecordingSendRules {

    /** The demo account's recordings stay on the phone: the server refuses its uploads. */
    fun sends(signedIn: Boolean, emailVerified: Boolean, demo: Boolean): Boolean = signedIn && emailVerified && !demo

    /** Of the unsent recordings' [keys], those to send now: none on their way already, and none
     *  the server refused this session unless the user asked again ([retry]), so a refusal isn't
     *  sent on every return to the app. */
    fun toSend(keys: List<String>, onItsWay: Set<String>, refused: Set<String>, retry: Boolean): List<String> =
        keys.filter { it !in onItsWay && (retry || it !in refused) }

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

    fun note(sending: Boolean, refusedReason: String?): Note = when {
        sending -> Note.Sending
        refusedReason != null -> Note.Refused(refusedReason)
        else -> Note.Waiting
    }
}
