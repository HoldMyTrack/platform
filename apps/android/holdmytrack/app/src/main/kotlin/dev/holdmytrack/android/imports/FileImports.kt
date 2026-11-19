package dev.holdmytrack.android.imports

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import dev.holdmytrack.android.R
import dev.holdmytrack.android.net.FailureText
import dev.holdmytrack.android.net.HoldMyTrackApi
import dev.holdmytrack.android.net.Session
import java.io.File
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The files the Upload screen sends to `POST /v2/tracks/upload` — the web's Upload menu
 * (`services/server/internal/web/static/upload.js`, root `docs/SPEC.md` FR-3.1–FR-3.2) on the
 * phone: `.gpx`, `.fit` and `.tcx`, up to 20 at a time. A `.zip` is refused with a note:
 * archives aren't imported (ADR-0039). One file at a time, in the order picked, each with its
 * progress.
 *
 * Process-wide rather than the screen's, so an upload carries on through a rotation or a trip to
 * another app; `UploadActivity` only draws [transfers] and [notes] and listens for changes. Each
 * file is copied into the app's cache as it's queued, off the main thread: the read grant on a
 * picked or shared file ends with the screen that received it, and the queue outlives the
 * screen. The queue belongs to the account that filled it ([ImportsAccount]). The server takes
 * it from there: once a file has gone, its jobs are in Sync's history, which polls while they
 * process.
 */
object FileImports {

    /** One picked file waiting or going. [sent] is the bytes sent so far, or -1 while queued. */
    class Transfer(val name: String, val size: Long) {
        var sent: Long = -1
            internal set
    }

    /** What a finished upload had to say that the history won't — already imported before,
     *  refused — or why a picked file wasn't sent. */
    data class Note(val text: String, val error: Boolean)

    private class Pending(val copy: File, val transfer: Transfer)

    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val queue = ArrayDeque<Pending>()
    private var running = false

    /** The account whose files these are: [Session.email] when they were queued. */
    private var owner: String? = null

    private val _transfers = mutableListOf<Transfer>()
    val transfers: List<Transfer> get() = _transfers

    private val _notes = mutableListOf<Note>()
    val notes: List<Note> get() = _notes

    /** Bumped each time a file has reached the server, so the Upload screen knows to point to
     *  Sync's history. */
    var sentCount = 0
        private set

    private val listeners = mutableSetOf<() -> Unit>()

    /** The application, from the first [enqueue], for [forAccount] as the session ends. */
    private var app: Context? = null

    init {
        // The copies of the account's files go as it signs out, not when the next one queues.
        Session.onClear { app?.let { forAccount(it, null) } }
    }

    fun addListener(listener: () -> Unit) {
        listeners += listener
    }

    fun removeListener(listener: () -> Unit) {
        listeners -= listener
    }

    private fun changed() = listeners.toList().forEach { it() }

    /**
     * Queues [uris] the way the web's upload does ([UploadPlan]): what it refuses is named in a
     * note rather than sent. Names and sizes come from the providers, and the copies are made,
     * on the I/O dispatcher, since a cloud drive's provider can take seconds.
     */
    fun enqueue(context: Context, uris: List<Uri>) {
        val app = context.applicationContext
        this.app = app
        val res = app.resources
        forAccount(app, Session.email)
        owner = Session.email
        scope.launch {
            if (!running && queue.isEmpty()) clearCopies(app)
            val picked = withContext(Dispatchers.IO) { uris.map { UploadPlan.Picked(nameOf(app, it), sizeOf(app, it)) } }
            val plan = UploadPlan.of(picked)
            _notes.clear()
            for (refusal in plan.refusals) {
                val text = when (refusal) {
                    is UploadPlan.Refusal.Zip -> res.getString(R.string.upload_zip_refused, refusal.name)
                    is UploadPlan.Refusal.WrongType -> res.getString(R.string.upload_wrong_type, refusal.name)
                    is UploadPlan.Refusal.TooMany -> res.getString(R.string.upload_too_many, refusal.count)
                    is UploadPlan.Refusal.TooLarge -> res.getString(R.string.upload_too_large, refusal.name, UploadPlan.MAX_FILE_BYTES shr 20)
                }
                _notes += Note(text, error = true)
            }
            for (i in plan.send) {
                val copy = withContext(Dispatchers.IO) { copyOf(app, uris[i]) }
                if (copy == null) {
                    _notes += Note(res.getString(R.string.upload_failed_transfer, picked[i].name, res.getString(R.string.upload_unreadable)), error = true)
                    continue
                }
                // A provider that didn't say its size is checked on the copy.
                if (copy.length() > UploadPlan.MAX_FILE_BYTES) {
                    copy.delete()
                    _notes += Note(res.getString(R.string.upload_too_large, picked[i].name, UploadPlan.MAX_FILE_BYTES shr 20), error = true)
                    continue
                }
                val transfer = Transfer(picked[i].name, copy.length())
                _transfers += transfer
                queue += Pending(copy, transfer)
            }
            changed()
            if (!running) sendNext(app)
        }
    }

    /**
     * Drops what another account left: its queue, its notes and its count. Called on queueing, as the session ends,
     * before each file is sent and when the Upload screen shows, so a phone signed in with
     * someone else never sends or shows the last account's files.
     */
    fun forAccount(context: Context, email: String?) {
        if (ImportsAccount.keeps(owner, email)) return
        owner = null
        queue.forEach { it.copy.delete() }
        queue.clear()
        _transfers.removeAll { it.sent < 0 }
        _notes.clear()
        sentCount = 0
        if (!running) clearCopies(context)
        changed()
    }

    private fun sendNext(context: Context) {
        forAccount(context, Session.email.takeIf { Session.isSignedIn })
        val next = queue.removeFirstOrNull()
        if (next == null) {
            running = false
            return
        }
        running = true
        val res = context.resources
        val transfer = next.transfer
        transfer.sent = 0
        changed()
        scope.launch {
            try {
                // Redrawn once a percent, not once a chunk: a 16 MiB file is 256 chunks.
                var shown = -1L
                val outcome = HoldMyTrackApi.uploadTrackFile(context.contentResolver, Uri.fromFile(next.copy), transfer.name, transfer.size) { sent ->
                    val percent = if (transfer.size > 0) sent * 100 / transfer.size else sent shr 20
                    if (percent == shown) return@uploadTrackFile
                    shown = percent
                    main.post {
                        transfer.sent = sent
                        changed()
                    }
                }
                sentCount++
                if (outcome.status == "already_processed") _notes += Note(res.getString(R.string.upload_already, transfer.name), error = false)
            } catch (e: Exception) {
                val reason = FailureText.of(e, res.getString(R.string.something_went_wrong), res.getString(R.string.network_error))
                _notes += Note(res.getString(R.string.upload_failed_transfer, transfer.name, reason), error = true)
            } finally {
                next.copy.delete()
                _transfers -= transfer
                changed()
                sendNext(context)
            }
        }
    }

    /** A copy of [uri] in the app's cache, or null when the provider won't hand it over. */
    private fun copyOf(context: Context, uri: Uri): File? = runCatching {
        val file = File(copies(context), UUID.randomUUID().toString())
        context.contentResolver.openInputStream(uri)?.use { input ->
            file.outputStream().use { input.copyTo(it) }
            file
        }
    }.getOrNull()

    private fun copies(context: Context) = File(context.cacheDir, COPIES).apply { mkdirs() }

    /** Copies a killed process left behind, or a dropped queue's. */
    private fun clearCopies(context: Context) {
        copies(context).listFiles()?.forEach { it.delete() }
    }

    /** The file's own name, as the picker or the app that shared it gives it. */
    fun nameOf(context: Context, uri: Uri): String =
        query(context, uri, OpenableColumns.DISPLAY_NAME) { it.getString(0) } ?: uri.lastPathSegment.orEmpty()

    /** Its size, or -1 when the provider doesn't say; the copy's own length is what's sent. */
    private fun sizeOf(context: Context, uri: Uri): Long =
        query(context, uri, OpenableColumns.SIZE) { if (it.isNull(0)) null else it.getLong(0) } ?: -1

    private fun <T> query(context: Context, uri: Uri, column: String, read: (android.database.Cursor) -> T?): T? =
        runCatching {
            context.contentResolver.query(uri, arrayOf(column), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) read(cursor) else null
            }
        }.getOrNull()

    private const val COPIES = "imports"
}
