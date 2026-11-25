package dev.holdmytrack.android.sync

import android.content.Context
import android.util.Log
import dev.holdmytrack.android.net.Session
import dev.holdmytrack.android.recording.db.RecordedTrackStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Sends the saved recordings on this phone without a tick (`apps/android/docs/SPEC.md` FR-5.2):
 * on Save, on every return to the map, and on the Sync sheet's Retry. Each goes as the Sync tab
 * would send it ([SyncRunner]), then waits in [SyncProgress] until its ingest lands, so a
 * recording leaves the phone only once the account has it.
 *
 * Process-wide, as `imports/FileImports` is: a send outlives the screen that started it. It reads
 * nothing from Health Connect, so the foreground rule for routes doesn't apply. What the server
 * refused is kept for this process and sent again only on Retry ([RecordingSendRules.toSend]).
 */
object RecordingSends {

    private const val TAG = "RecordingSends"

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var running = false

    /** A send asked for while one ran, which picked its recordings already: it runs after. */
    private var again = false

    /** The account the refusals below belong to. */
    private var account: String? = null

    /** Recording keys going now. */
    private var sending: Set<String> = emptySet()

    /** Recording keys whose Delete is being asked about, which no send takes meanwhile. */
    private val held = mutableSetOf<String>()

    /** Recording keys the server refused, with its reason. */
    private val refused = mutableMapOf<String, String>()

    /** Recording keys whose last request got no answer, the latest last: last in the next send. */
    private val unanswered = mutableListOf<String>()

    private val listeners = mutableSetOf<() -> Unit>()

    fun addListener(listener: () -> Unit) {
        listeners += listener
    }

    fun removeListener(listener: () -> Unit) {
        listeners -= listener
    }

    /** What the row of the recording with this [key] says. */
    fun note(key: String, hidden: Boolean): RecordingSendRules.Note? {
        forThisAccount()
        return RecordingSendRules.note(key in sending, hidden, refused[key])
    }

    /** Keeps the recording with this [key] out of any send while its Delete is asked about, or a
     *  return to the app would send it from under the question. */
    fun hold(key: String) {
        held += key
    }

    /** The question closed: what's kept goes now. */
    fun release(context: Context, key: String) {
        if (held.remove(key)) send(context)
    }

    /** What Delete does with the recording with this [key]; [stored], whether the phone has it. */
    fun deletion(key: String, stored: Boolean) = RecordingSendRules.deletion(stored, going = key in sending || SyncProgress.isProcessing(key))

    /** Sends what's waiting; [retry] sends what the server refused too. One asked for during a
     *  send runs after it; an account that can't send does nothing. */
    fun send(context: Context, retry: Boolean = false) {
        if (!RecordingSendRules.sends(Session.isSignedIn, Session.emailVerified, Session.isDemo)) return
        if (running) {
            again = true
            return
        }
        forThisAccount()
        val app = context.applicationContext
        running = true
        scope.launch {
            try {
                val store = RecordedTrackStore(app)
                val waiting = store.all().map { SyncCandidates.fromRecording(it) }
                val onItsWay = SyncProgress.candidates.mapTo(HashSet()) { it.key }
                val keys = RecordingSendRules.toSend(waiting.map { it.key }, onItsWay, HiddenCandidates(app, Session.email).all(), held, refused.keys, unanswered, retry)
                val batch = keys.mapNotNull { key -> waiting.find { it.key == key } }
                if (batch.isEmpty()) return@launch
                sending = keys.toSet()
                changed()
                SyncRunner(store, app.resources, healthConnect = null).send(
                    batch,
                    onLanded = { landed ->
                        // Only an answer clears a refusal: a run with no connection keeps it.
                        for (candidate in landed) refused -= candidate.key
                        SyncProgress.add(app, landed)
                    },
                    onRejected = { refused[it.key] = it.reason },
                    // Swiped aside since the batch was picked, by an Undo.
                    skip = { it.key in HiddenCandidates(app, Session.email).all() },
                    onAnswered = { candidate, answered ->
                        unanswered -= candidate.key
                        if (!answered) unanswered += candidate.key
                    },
                ) {}
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // Nothing decided: each stays waiting and goes on the next try.
                Log.w(TAG, "could not send recordings", e)
            } finally {
                running = false
                sending = emptySet()
                changed()
                if (again) {
                    again = false
                    send(app)
                }
            }
        }
    }

    /** The server's job for a sent recording failed ([SyncProgress]): refused until Retry, so it
     *  isn't sent again on every return. */
    fun failedOnServer(key: String, reason: String) {
        refused[key] = reason
        changed()
    }

    private fun forThisAccount() {
        if (account == Session.email) return
        account = Session.email
        refused.clear()
        unanswered.clear()
    }

    private fun changed() = listeners.toList().forEach { it() }
}
