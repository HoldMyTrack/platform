package dev.holdmytrack.android.imports

import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import dev.holdmytrack.android.R
import dev.holdmytrack.android.net.HoldMyTrackApi
import dev.holdmytrack.android.net.ImportFailure
import dev.holdmytrack.android.net.Session
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * The alert for imports that failed on the server's side (root `docs/SPEC.md` FR-3.7): files
 * uploaded and tracks synced alike, each with its reason. A file the server can't use is refused
 * when it is sent, so only a fault on the server's side gets here. Read whenever the map comes to
 * the front and when a sync finds a row failed; closing the alert dismisses what it listed, so
 * a later failure gets an alert of its own.
 */
object ImportFailureAlert {

    /** An alert is up, or a read for one is under way: a second check waits for it to close. */
    private var busy = false

    /** Dismissals outlive the screen that closed the alert. */
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    /** The alert's text: one paragraph per failure, its title and reason. */
    fun message(failures: List<ImportFailure>): String = failures.joinToString("\n\n") { "${it.title}: ${it.reason}" }

    /** Reads the unseen failures and shows them over [activity], for a verified account that can
     *  send. A failed read is let go: the next check reads again. */
    fun check(activity: AppCompatActivity) {
        if (busy || !Session.isSignedIn || Session.isDemo || !Session.emailVerified) return
        busy = true
        activity.lifecycleScope.launch {
            // Free again however the read ends, the screen closing under it included.
            val failures = try {
                runCatching { HoldMyTrackApi.importFailures() }.getOrNull().orEmpty()
            } finally {
                busy = false
            }
            if (failures.isEmpty() || !activity.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) return@launch
            busy = true
            MaterialAlertDialogBuilder(activity)
                .setTitle(activity.resources.getQuantityString(R.plurals.import_failed_title, failures.size, failures.size))
                .setMessage(message(failures))
                .setPositiveButton(android.R.string.ok, null)
                .setOnDismissListener {
                    busy = false
                    scope.launch { for (f in failures) runCatching { HoldMyTrackApi.dismissImportFailure(f.id) } }
                }
                .show()
        }
    }
}
