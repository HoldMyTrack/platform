package dev.holdmytrack.android.settings

import android.util.Log
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.android.material.textfield.TextInputEditText
import com.google.android.material.textfield.TextInputLayout
import dev.holdmytrack.android.R
import dev.holdmytrack.android.SignInActivity
import dev.holdmytrack.android.map.EmptyNoticeDismissal
import dev.holdmytrack.android.net.HoldMyTrackApi
import dev.holdmytrack.android.net.Session
import dev.holdmytrack.android.recording.RecordingService
import dev.holdmytrack.android.recording.RecordingTypes
import dev.holdmytrack.android.recording.db.RecordedTrackStore
import dev.holdmytrack.android.sync.HiddenCandidates
import dev.holdmytrack.android.sync.SyncSources
import dev.holdmytrack.android.sync.WaitingStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Delete account (root `docs/SPEC.md` FR-1.12), from the You tab, as on the web: a dialog asks
 * for the account's email, the server closes the account, and this device forgets it.
 */
object AccountDeletion {

    /** The email typed into a dialog, as the web's form asks for it. The server says whether it
     *  matched; the dialog stays up with its error until it does or is cancelled. */
    fun confirm(activity: AppCompatActivity) {
        val view = activity.layoutInflater.inflate(R.layout.dialog_delete_account, null)
        val layout = view.findViewById<TextInputLayout>(R.id.delete_email_layout)
        val field = view.findViewById<TextInputEditText>(R.id.delete_email)
        view.findViewById<TextView>(R.id.delete_message).text = activity.getString(R.string.settings_delete_confirm, Session.email)
        // What goes, above how to confirm: the You tab's button says no more than "Delete account…".
        val dialog = MaterialAlertDialogBuilder(activity, R.style.ThemeOverlay_HoldMyTrack_Dialog_Destructive)
            .setTitle(R.string.settings_delete_title)
            .setMessage(R.string.settings_delete_hint)
            .setView(view)
            .setNegativeButton(android.R.string.cancel, null)
            .setPositiveButton(R.string.settings_delete_submit, null)
            .show()
        val confirm = dialog.getButton(android.app.AlertDialog.BUTTON_POSITIVE)
        confirm.setOnClickListener {
            layout.error = null
            confirm.isEnabled = false
            HoldMyTrackApi.deleteAccount(field.text.toString()) { result ->
                result.onSuccess {
                    // Before the dismiss: after a rotation the dialog belongs to a destroyed
                    // screen, and closing it can throw.
                    forget(activity)
                    runCatching { dialog.dismiss() }
                }.onFailure {
                    if (activity.isDestroyed) return@onFailure
                    confirm.isEnabled = true
                    layout.error = it.message.orEmpty()
                }
            }
        }
    }

    /** Outlives the screen: the server has deleted the account by now, and a rotation must
     *  not cut the device's half short. */
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private const val TAG = "AccountDeletion"

    /**
     * What this device keeps for the deleted account goes too: its unsynced recordings and any
     * recording left in the journal, the last recording type, the rows it hid on the Sync tab,
     * its Health Connect switch and what Load last read — all keyed by the email, which a new
     * account can take again — then the session, and on to the sign-in screen, which says the
     * account was deleted.
     */
    private fun forget(activity: AppCompatActivity) {
        val email = Session.email
        val context = activity.applicationContext
        scope.launch {
            // Each step on its own: one that fails (a full disk) mustn't keep the rest, or the
            // sign-out, from running, since the account is already gone on the server.
            val steps = listOf<suspend () -> Unit>(
                { RecordedTrackStore(context).deleteAll() },
                { RecordingService.forgetAccount(context, email) },
                { RecordingTypes.forget(context, email) },
                { HiddenCandidates(context, email).clear() },
                { SyncSources(context, email).clear() },
                { EmptyNoticeDismissal(context, email).clear() },
                { WaitingStore(context).clear() },
            )
            for (step in steps) {
                try {
                    step()
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    Log.w(TAG, "account deletion: a local cleanup step failed", e)
                }
            }
            Session.clear()
            SignInActivity.open(context, R.string.account_deleted)
        }
    }
}
