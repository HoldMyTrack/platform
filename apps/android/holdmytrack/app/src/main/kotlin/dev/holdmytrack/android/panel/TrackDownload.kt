package dev.holdmytrack.android.panel

import android.net.Uri
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.fragment.app.Fragment
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.lifecycleScope
import dev.holdmytrack.android.R
import dev.holdmytrack.android.net.FailureText
import dev.holdmytrack.android.net.HoldMyTrackApi
import java.io.File
import java.util.concurrent.Executors
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.launch

/**
 * Download (root `docs/SPEC.md` FR-17.2), Library's and the Tracks panel's: the tracks as one GPX, or a zip of them,
 * fetched into the cache and then saved where the user picks on Android's save screen, with no
 * storage permission. Made with its fragment, since the save screen's launchers must be
 * registered before it starts.
 *
 * A download that finishes while the app is away waits for the fragment to be back in front to
 * offer the save screen: one opened from the background would pop over another app, or be
 * blocked. One cut off by the fragment closing is dropped without a word.
 */
class TrackDownload(private val fragment: Fragment) {

    private val saveGpx = fragment.registerForActivityResult(ActivityResultContracts.CreateDocument(GpxDownload.mimeType("tracks.gpx"))) { save(it) }
    private val saveZip = fragment.registerForActivityResult(ActivityResultContracts.CreateDocument(GpxDownload.mimeType("tracks.zip"))) { save(it) }

    /** A download is under way: a second Download waits for it. */
    var busy = false
        private set

    /** A downloaded file's name, waiting for the fragment to be in front. */
    private var waiting: String? = null

    init {
        fragment.lifecycle.addObserver(
            LifecycleEventObserver { _, event ->
                if (event == Lifecycle.Event.ON_START) waiting?.let {
                    waiting = null
                    offer(it)
                }
            },
        )
    }

    /** Downloads [ids] and offers to save them. */
    fun start(ids: List<String>) {
        if (busy || ids.isEmpty()) return
        val context = fragment.context ?: return
        // Found before busy is set: a return after it would leave every later Download refused.
        val file = file() ?: return
        busy = true
        Toast.makeText(context, R.string.library_downloading, Toast.LENGTH_SHORT).show()
        fragment.lifecycleScope.launch {
            try {
                val name = HoldMyTrackApi.downloadTracksGpx(ids, file)
                if (fragment.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) offer(name) else waiting = name
            } catch (e: CancellationException) {
                file.delete()
                throw e
            } catch (e: Exception) {
                file.delete()
                val res = fragment.resources
                val reason = FailureText.of(e, res.getString(R.string.something_went_wrong), res.getString(R.string.network_error))
                Toast.makeText(fragment.requireContext(), reason, Toast.LENGTH_LONG).show()
            } finally {
                busy = false
            }
        }
    }

    private fun offer(name: String) {
        (if (GpxDownload.mimeType(name) == GpxDownload.mimeType("tracks.zip")) saveZip else saveGpx).launch(name)
    }

    /** Copies the downloaded file to where the save screen put [uri], or drops it when cancelled. */
    private fun save(uri: Uri?) {
        val file = file() ?: return
        if (uri == null) {
            file.delete()
            return
        }
        val context = fragment.requireContext().applicationContext
        io.execute {
            val saved = runCatching {
                context.contentResolver.openOutputStream(uri)!!.use { out -> file.inputStream().use { it.copyTo(out) } }
            }.isSuccess
            file.delete()
            fragment.activity?.runOnUiThread {
                Toast.makeText(context, if (saved) R.string.library_saved else R.string.library_save_failed, Toast.LENGTH_SHORT).show()
            }
        }
    }

    private fun file(): File? = fragment.context?.cacheDir?.let { File(it, DOWNLOAD_FILE) }

    private companion object {
        const val DOWNLOAD_FILE = "track-download"
        val io = Executors.newSingleThreadExecutor()
    }
}
