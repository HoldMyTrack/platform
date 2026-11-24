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

    /** The account the refusals below belong to. */
    private var account: String? = null

    /** Recording keys going now. */
    private var sending: Set<String> = emptySet()

    /** Recording keys the server refused, with its reason. */
    private val refused = mutableMapOf<String, String>()

    private val listeners = mutableSetOf<() -> Unit>()

    fun addListener(listener: () -> Unit) {
        listeners += listener
    }

    fun removeListener(listener: () -> Unit) {
        listeners -= listener
    }

    /** What the row of the recording with this [key] says. */
    fun note(key: String): RecordingSendRules.Note {
        forThisAccount()
        return RecordingSendRules.note(key in sending, refused[key])
    }

    /** Sends what's waiting; [retry] sends what the server refused too. A send under way, or an
     *  account that can't send, does nothing. */
    fun send(context: Context, retry: Boolean = false) {
        if (running || !RecordingSendRules.sends(Session.isSignedIn, Session.emailVerified, Session.isDemo)) return
        forThisAccount()
        val app = context.applicationContext
        running = true
        scope.launch {
            try {
                val store = RecordedTrackStore(app)
                val waiting = store.all().map { SyncCandidates.fromRecording(it) }
                val onItsWay = SyncProgress.candidates.mapTo(HashSet()) { it.key }
                val keys = RecordingSendRules.toSend(waiting.map { it.key }, onItsWay, refused.keys, retry).toSet()
                val batch = waiting.filter { it.key in keys }
                if (batch.isEmpty()) return@launch
                sending = keys
                changed()
                val report = SyncRunner(store, app.resources, healthConnect = null).send(batch, onLanded = { SyncProgress.add(app, it) }) {}
                for (key in keys) refused -= key
                for (rejection in report.rejected) refused[rejection.key] = rejection.reason
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // Nothing decided: each stays waiting and goes on the next try.
                Log.w(TAG, "could not send recordings", e)
            } finally {
                running = false
                sending = emptySet()
                changed()
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
    }

    private fun changed() = listeners.toList().forEach { it() }
}
