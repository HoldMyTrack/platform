package dev.holdmytrack.android

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.text.TextUtils
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updatePadding
import com.google.android.material.bottomsheet.BottomSheetBehavior
import androidx.appcompat.app.AppCompatActivity
import dev.holdmytrack.android.imports.FileImports
import dev.holdmytrack.android.imports.SharedFiles
import dev.holdmytrack.android.net.Session

/**
 * Upload: files made somewhere else — a watch's or an app's export — brought into the account (`apps/docs/SPEC.md` FR-3.6).
 * The web's Upload menu as a sheet over the screen it opened from, the Sync tab or another app, kept apart from the Sync tab as Upload
 * sits apart from Sync in the web's header: Sync is for what lives on the phone and keeps coming, this is for a file,
 * usually once. The uploads themselves are [FileImports]'s, so they carry on when this screen
 * goes; once one has gone, its tracks are in Library.
 *
 * Another app's `.gpx` or `.tcx` handed to this app to open or share lands here, listed, and
 * goes only on the user's Upload ([SharedFiles]). An activity rather than a sheet on the map, since
 * the read grant for those files is this activity's.
 *
 * Dragged down, Back or a tap on the scrim closes it; the uploads carry on, so nothing holds it open.
 */
class UploadActivity : AppCompatActivity() {

    private lateinit var accountNotice: TextView
    private lateinit var section: View
    private lateinit var choose: Button
    private lateinit var transfers: LinearLayout
    private lateinit var notes: TextView
    private lateinit var errors: TextView
    private lateinit var seeLibrary: Button
    private lateinit var sharedSection: View
    private lateinit var sharedNames: TextView

    /** Files another app handed over, waiting for Upload or Cancel. */
    private var shared: List<Uri> = emptyList()

    private val listener: () -> Unit = { render() }

    // Any type: providers label .gpx and .fit all sorts of ways, and FileImports says which it won't send.
    private val picker = registerForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        if (uris.isNotEmpty()) importFiles(uris)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_upload)
        installSheet(slideIn = savedInstanceState == null)

        accountNotice = findViewById(R.id.upload_account_notice)
        section = findViewById(R.id.upload_section)
        choose = findViewById(R.id.upload_choose)
        transfers = findViewById(R.id.upload_transfers)
        notes = findViewById(R.id.upload_notes)
        errors = findViewById(R.id.upload_errors)
        seeLibrary = findViewById(R.id.upload_see_library)
        sharedSection = findViewById(R.id.upload_shared)
        sharedNames = findViewById(R.id.upload_shared_names)

        choose.setOnClickListener { picker.launch(arrayOf("*/*")) }
        seeLibrary.setOnClickListener {
            MainActivity.openTab(this, MainActivity.Tab.LIBRARY)
            finish()
        }

        findViewById<Button>(R.id.upload_shared_send).setOnClickListener {
            val uris = shared
            setShared(emptyList())
            importFiles(uris)
        }
        findViewById<Button>(R.id.upload_shared_cancel).setOnClickListener { setShared(emptyList()) }

        // A recreation keeps the list as it stood, the files of a later share included; the read
        // grants stay with the activity.
        setShared(savedInstanceState?.getParcelableArrayList(KEY_SHARED, Uri::class.java) ?: sharedFiles(intent))
    }

    private lateinit var sheet: BottomSheetBehavior<View>

    /** The sheet over a scrim that fades with it; hidden, the activity finishes. It clears the
     *  status bar at the top, and its content the navigation bar at the bottom. */
    private fun installSheet(slideIn: Boolean) {
        val scrim = findViewById<View>(R.id.upload_scrim)
        val scrimColor = scrim.background.mutate()
        val body = findViewById<View>(R.id.upload_body)
        val bodyBottom = body.paddingBottom
        sheet = BottomSheetBehavior.from(findViewById(R.id.upload_sheet))
        sheet.state = if (slideIn) BottomSheetBehavior.STATE_HIDDEN else BottomSheetBehavior.STATE_EXPANDED
        if (slideIn) scrimColor.alpha = 0
        sheet.addBottomSheetCallback(object : BottomSheetBehavior.BottomSheetCallback() {
            override fun onStateChanged(view: View, state: Int) {
                if (state == BottomSheetBehavior.STATE_HIDDEN && !isFinishing) {
                    finish()
                    overrideActivityTransition(OVERRIDE_TRANSITION_CLOSE, 0, 0)
                }
            }

            override fun onSlide(view: View, offset: Float) {
                scrimColor.alpha = ((1 + offset).coerceIn(0f, 1f) * 255).toInt()
            }
        })
        if (slideIn) scrim.post { sheet.state = BottomSheetBehavior.STATE_EXPANDED }
        scrim.setOnClickListener { close() }
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() = close()
        })
        ViewCompat.setOnApplyWindowInsetsListener(scrim) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            view.setPadding(bars.left, bars.top, bars.right, 0)
            body.updatePadding(bottom = bodyBottom + bars.bottom)
            insets
        }
    }

    private fun close() {
        sheet.state = BottomSheetBehavior.STATE_HIDDEN
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // Added to what is still waiting: a second share doesn't drop the first.
        setShared((shared + sharedFiles(intent)).distinct())
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putParcelableArrayList(KEY_SHARED, ArrayList(shared))
    }

    override fun onStart() {
        super.onStart()
        // Another account's queue and notes go before this one sees them.
        FileImports.forAccount(this, Session.email.takeIf { Session.isSignedIn })
        FileImports.addListener(listener)
        render()
    }

    override fun onStop() {
        FileImports.removeListener(listener)
        super.onStop()
    }

    /** The server refuses a demo account's uploads (`requireNotDemo`) and an unconfirmed one's. */
    private fun canUpload() = Session.isSignedIn && Session.emailVerified && !Session.isDemo

    /** Files another app handed this one to open or share. */
    private fun sharedFiles(intent: Intent?): List<Uri> {
        val streams = when (intent?.action) {
            Intent.ACTION_SEND -> listOfNotNull(intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java))
            Intent.ACTION_SEND_MULTIPLE -> intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
            else -> emptyList()
        }
        return SharedFiles.of(intent?.action, intent?.data, streams) { it.scheme }
    }

    private fun setShared(uris: List<Uri>) {
        shared = uris
        sharedNames.text = uris.joinToString("\n") { FileImports.nameOf(this, it) }
        render()
    }

    /** Picked or shared files to [FileImports]. */
    private fun importFiles(uris: List<Uri>) {
        FileImports.enqueue(this, uris)
    }

    /** The account gate, then each file queued or uploading, the uploads' notes and errors, and
     *  the way to Sync once anything has gone. */
    private fun render() {
        if (!canUpload()) {
            accountNotice.setText(
                when {
                    !Session.isSignedIn -> R.string.sync_needs_account
                    !Session.emailVerified -> R.string.sync_needs_verified_email
                    else -> R.string.upload_demo
                },
            )
            accountNotice.visibility = View.VISIBLE
            for (view in listOf(section, sharedSection, choose, transfers, notes, errors, seeLibrary)) view.visibility = View.GONE
            return
        }
        accountNotice.visibility = View.GONE
        sharedSection.visibility = if (shared.isEmpty()) View.GONE else View.VISIBLE

        transfers.removeAllViews()
        for (transfer in FileImports.transfers) {
            val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
            val name = TextView(this).apply {
                text = transfer.name
                maxLines = 1
                ellipsize = TextUtils.TruncateAt.MIDDLE
            }
            val status = TextView(this).apply {
                setTextColor(getColor(R.color.hmt_ink_meta))
                text = when {
                    transfer.sent < 0 -> getString(R.string.upload_queued)
                    transfer.size > 0 -> getString(R.string.upload_uploading, (transfer.sent * 100 / transfer.size).toInt())
                    else -> getString(R.string.upload_uploading_mb, (transfer.sent shr 20).toInt())
                }
            }
            row.addView(name, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            row.addView(status)
            transfers.addView(row)
        }
        val (bad, good) = FileImports.notes.partition { it.error }
        notes.text = good.joinToString("\n") { it.text }
        notes.visibility = if (good.isEmpty()) View.GONE else View.VISIBLE
        errors.text = bad.joinToString("\n") { it.text }
        errors.visibility = if (bad.isEmpty()) View.GONE else View.VISIBLE
        seeLibrary.visibility = if (FileImports.sentCount > 0) View.VISIBLE else View.GONE
    }

    private companion object {
        const val KEY_SHARED = "shared"
    }
}
