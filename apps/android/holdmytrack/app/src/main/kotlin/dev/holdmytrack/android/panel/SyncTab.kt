package dev.holdmytrack.android.panel

import android.app.Dialog
import android.content.Intent
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.isVisible
import androidx.recyclerview.widget.ConcatAdapter
import androidx.recyclerview.widget.ItemTouchHelper
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.google.android.material.chip.Chip
import com.google.android.material.chip.ChipGroup
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.android.material.snackbar.Snackbar
import dev.holdmytrack.android.MainActivity
import dev.holdmytrack.android.R
import dev.holdmytrack.android.SyncActivity
import dev.holdmytrack.android.UploadActivity
import dev.holdmytrack.android.health.HealthConnect
import dev.holdmytrack.android.imports.ImportFailureAlert
import dev.holdmytrack.android.net.FailureText
import dev.holdmytrack.android.net.TrackOverlap
import dev.holdmytrack.android.net.HoldMyTrackApi
import dev.holdmytrack.android.net.OverlapSpan
import dev.holdmytrack.android.net.Session
import dev.holdmytrack.android.recording.RecordingActivity
import dev.holdmytrack.android.recording.RecordingTypes
import dev.holdmytrack.android.recording.db.RecordedTrackStore
import dev.holdmytrack.android.sync.ReadDue
import dev.holdmytrack.android.sync.RecordingSendRules
import dev.holdmytrack.android.sync.RecordingSends
import dev.holdmytrack.android.sync.Candidate
import dev.holdmytrack.android.sync.HealthConnectCard.Companion.isReadable
import dev.holdmytrack.android.sync.HiddenCandidates
import dev.holdmytrack.android.sync.Similar
import dev.holdmytrack.android.sync.SimilarTracksSheet
import dev.holdmytrack.android.sync.SyncCandidates
import dev.holdmytrack.android.sync.SyncList
import dev.holdmytrack.android.sync.SyncProgress
import dev.holdmytrack.android.sync.SyncReport
import dev.holdmytrack.android.sync.SyncRunner
import dev.holdmytrack.android.sync.SyncSources
import dev.holdmytrack.android.sync.WaitingLoader
import dev.holdmytrack.android.sync.WaitingStore
import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/**
 * The Tracks sheet's Sync tab — the bottom bar's Sync (`docs/SPEC.md` FR-3.4, FR-3.6): every
 * track on this phone that isn't on the map yet, the user's to choose. Health Connect's
 * sessions with a route from the last three months, and every recording waiting on the phone,
 * newest first ([SyncCandidates]), each drawn dashed on the map while the tab shows
 * ([onCandidates]). **Nothing is ticked**: only what the user ticks is sent ([SyncRunner]), and
 * an unticked row never reaches the server. A row that covers the same time as another, or as an
 * track the account has, carries an ⓘ ([SimilarTracksSheet]) — a hint, never a choice made
 * for the user. A row swiped aside is hidden ([HiddenCandidates]) —
 * Show hidden brings it back. Under the list, Upload files and Sync history, each a screen of its
 * own, and the way to Health Connect access (`SyncActivity`), where Health Connect is switched on and
 * set up: it isn't read here until it is ([SyncSources]).
 *
 * Health Connect is read only when the user taps **Load** ([WaitingLoader]) — or once by
 * itself after it's switched on — and its sessions are kept as last read ([WaitingStore]), so
 * opening the tab lists them again, with when they were read, without reading anything.
 * Recordings are on the phone already, and listed as they are each time.
 *
 * **Foreground only** (`docs/IMPLEMENTATION.md` §4.0): routes written by other apps read back as
 * `ConsentRequired` in the background, so a read or a run in progress is cancelled when the tab
 * leaves the screen ([stop], [pause]); a run cut off is safe, the server being idempotent.
 */
class SyncTab(
    private val content: View,
    private val activity: AppCompatActivity,
    /** The scope reads and runs go in — the map's view's, so they end with it. */
    private val scope: () -> CoroutineScope,
    /** What the map draws: the listed candidates, [Candidate.key] `highlight` picked out. */
    private val onCandidates: (candidates: List<Candidate>, highlight: String?) -> Unit,
    /** Frame these on the map. */
    private val onFrame: (List<Candidate>) -> Unit,
    /** A run sent something: the map's tracks, its days and its tiles are out of date. */
    private val onSynced: () -> Unit,
    /** A row was hidden, brought back or deleted: what's waiting to be sent changed. */
    private val onWaitingChanged: () -> Unit,
) {
    private val res = content.resources
    private val store = RecordedTrackStore(activity)

    // Its layout manager first: the head and foot are inflated against it.
    private val list: RecyclerView = content.findViewById<RecyclerView>(R.id.sync_list).apply {
        layoutManager = LinearLayoutManager(activity)
    }
    private val bar: View = content.findViewById(R.id.sync_bar)
    private val progress: View = content.findViewById(R.id.sync_progress)
    private val tickedLine: TextView = content.findViewById(R.id.sync_ticked)
    private val syncNow: Button = content.findViewById(R.id.sync_now)
    private val waiting = WaitingStore(activity)

    private val head: View = LayoutInflater.from(activity).inflate(R.layout.include_sync_head, list, false)
    private val accountNotice: TextView = head.findViewById(R.id.sync_account_notice)
    private val results: TextView = head.findViewById(R.id.sync_results)
    private val problems: TextView = head.findViewById(R.id.sync_problems)
    private val sourceRow: View = head.findViewById(R.id.sync_source_row)
    private val sourceStatus: TextView = head.findViewById(R.id.sync_source_status)
    private val refresh: Button = head.findViewById(R.id.sync_refresh)
    private val sourceNote: TextView = head.findViewById(R.id.sync_source_note)
    private val recordingsRow: View = head.findViewById(R.id.sync_recordings_row)
    private val recordingsStatus: TextView = head.findViewById(R.id.sync_recordings_status)
    private val recordingsRetry: Button = head.findViewById(R.id.sync_recordings_retry)
    private val sourceSettings: Button = head.findViewById(R.id.sync_source_settings)
    private val filters: View = head.findViewById(R.id.sync_filters)
    private val typeChips: ChipGroup = head.findViewById(R.id.sync_types)
    private val selectAll: Button = head.findViewById(R.id.sync_select_all)

    private val foot: View = LayoutInflater.from(activity).inflate(R.layout.include_sync_foot, list, false)
    private val listNote: TextView = foot.findViewById(R.id.sync_list_note)
    private val showHiddenButton: Button = foot.findViewById(R.id.sync_show_hidden)
    private val upload: View = content.findViewById(R.id.sync_upload)

    private val rows = SyncRowAdapter(
        SyncRowActions(
            tick = ::toggle,
            similar = { key -> candidate(key)?.let(::showSimilar) },
            show = { key -> candidate(key)?.let(::pick) },
            edit = { id -> activity.startActivity(Intent(activity, RecordingActivity::class.java).putExtra(RecordingActivity.EXTRA_RECORDING_ID, id)) },
            delete = { key -> candidate(key)?.let(::confirmDelete) },
        ),
    )

    private var showing = false
    private var loading = false
    private var readiness: HealthConnect.Readiness? = null

    /** Health Connect's sessions as last read — this time, or kept from before ([WaitingStore]),
     *  when they have no route with them — and which of them the account has since been sent. */
    private var sessions: List<Candidate> = emptyList()
    private var known: Set<String> = emptySet()
    /** When Health Connect was last read; null before the first Load. */
    private var checkedAt: Instant? = null
    /** Sessions sent whose ingest failed ([showFailed]): back in the kept list ([WaitingStore])
     *  before it's next read, since they left it when the server took them ([landed]). */
    private val keepAgain = mutableListOf<Candidate>()
    private var recordings: List<Candidate> = emptyList()
    private var hidden: Set<String> = emptySet()
    /** The account's track each candidate overlaps, by key — the hint, nothing more. */
    private var overlaps: Map<String, TrackOverlap> = emptyMap()
    /** The other waiting rows each one overlaps, by key ([Similar.waiting]), as last rendered. */
    private var similar: Map<String, List<Candidate>> = emptyMap()

    /** Similar tracks while open, dismissed when the tab goes. */
    private var similarSheet: MapSheet? = null
    /** The rows [similar] was worked out from: it compares every pair, so only a change redoes it. */
    private var similarOf: List<Candidate>? = null
    /** The lists as last rendered, for a tap to find its row in. */
    private var rendered: SyncList? = null
    private var showHidden = false

    /** What Health Connect couldn't give, said over the list. */
    private var sourceProblem: String? = null

    private val ticked = mutableSetOf<String>()

    /** The types shown; empty is every type. */
    private val types = mutableSetOf<String>()
    private var highlight: String? = null

    /** The camera framed this opening's list already. */
    private var framed = false

    private var loadJob: Job? = null
    private var runJob: Job? = null

    /** A row on its way landed — it leaves the list — or failed: it's back, and says so. */
    /** A landed recording has left the store: listed again without it. */
    private val progressListener = SyncProgress.Listener(onChange = ::progressed, onLanded = { if (showing) restore(opening = false) })

    /** A recording started or finished sending by itself ([RecordingSends]): the store changed. */
    private val recordingsListener: () -> Unit = { if (showing) restore(opening = false) }

    /** A type described after the rows showed changes their icons ([TrackTypes]). */
    private val onTypes: () -> Unit = { list.post { render() } }

    init {
        TrackTypes.addListener(onTypes)
        list.adapter = ConcatAdapter(ViewAdapter(head), rows, ViewAdapter(foot))
        ItemTouchHelper(SwipeToHide()).attachToRecyclerView(list)
        syncNow.setOnClickListener { startSync() }
        refresh.setOnClickListener { loadUpdates() }
        selectAll.setOnClickListener { toggleAll() }
        showHiddenButton.setOnClickListener {
            showHidden = !showHidden
            render()
        }
        upload.setOnClickListener { activity.startActivity(Intent(activity, UploadActivity::class.java)) }
        recordingsRetry.setOnClickListener { RecordingSends.send(activity, retry = true) }
        for (link in listOf(head.findViewById<View>(R.id.sync_source_access), sourceSettings)) {
            link.setOnClickListener { activity.startActivity(Intent(activity, SyncActivity::class.java)) }
        }
    }

    /** The tab showed: what's kept listed again, nothing ticked. */
    fun start() {
        showing = true
        framed = false
        ticked.clear()
        types.clear()
        highlight = null
        results.visibility = View.GONE
        problems.visibility = View.GONE
        SyncProgress.addListener(progressListener)
        RecordingSends.addListener(recordingsListener)
        SyncProgress.resume(activity)
        showFailed()
        restore(opening = true)
    }

    /** The tab went: the map's lines go, and so does anything still reading or sending. */
    fun stop() {
        showing = false
        similarSheet?.dismiss()
        similarSheet = null
        destroy()
        SyncProgress.removeListener(progressListener)
        RecordingSends.removeListener(recordingsListener)
        pause()
        onCandidates(emptyList(), null)
    }

    /** The map's view is going, or the tab: Delete's question too, which would go with its window
     *  undismissed, and its recording stay held. */
    fun destroy() {
        deleteDialog?.dismiss()
    }

    /** Back on screen — from Health Connect access, a recording's Edit, or the app itself: what's kept
     *  listed again, keeping what's ticked. Health Connect isn't read. */
    fun resume() {
        if (!showing) return
        restore(opening = false)
    }

    /** Off screen: Health Connect's routes can't be read from the background. */
    fun pause() {
        loadJob?.cancel()
        loadJob = null
        runJob?.cancel()
        runJob = null
        loading = false
    }

    /** A line tapped on the map: its row picked out and scrolled to. */
    fun focus(key: String) {
        highlight = key
        render()
        val index = rows.currentList.indexOfFirst { it.key == key }
        if (index >= 0) list.scrollToPosition(index + 1)
    }

    /**
     * Lists what's kept: the recordings on the phone and Health Connect's sessions as they were
     * last read, and asks the server which tracks they overlap. Then it reads Health Connect when
     * it was just switched on ([SyncSources.firstLoadPending]), or, [opening] the tab, when it was
     * last read a minute or more ago ([ReadDue]).
     */
    private fun restore(opening: Boolean) {
        if (runJob != null || loading) return
        loadJob?.cancel()
        loadJob = scope().launch {
            if (keepAgain.isNotEmpty()) {
                waiting.put(keepAgain.toList())
                keepAgain.clear()
            }
            readiness = HealthConnect.readiness(activity)
            recordings = store.all().map { SyncCandidates.fromRecording(it) }
            val sources = SyncSources(activity, Session.email)
            if (!Session.isDemo && sources.healthConnect) {
                val saved = waiting.read()
                // Read this time, a session still has its route: kept rather than its copy.
                val read = sessions.associateBy { it.key }
                sessions = saved.sessions.map { read[it.key] ?: it }
                checkedAt = saved.checkedAt
                sourceProblem = saved.refused.takeIf { it > 0 }?.let { res.getQuantityString(R.plurals.sync_routes_refused, it, it) }
            } else {
                sessions = emptyList()
                checkedAt = null
                sourceProblem = null
            }
            // A hidden recording that's gone — synced, or deleted — needn't be remembered. Hidden
            // sessions are pruned by a whole Load ([WaitingLoader]).
            val hiddenStore = hiddenStore()
            val recordedPrefix = HoldMyTrackApi.SOURCE_RECORDED + ":"
            hiddenStore.retainOnly(recordings.map { it.key }.toSet() + hiddenStore.all().filterNot { it.startsWith(recordedPrefix) })
            hidden = hiddenStore.all()
            ticked.retainAll(all().map { it.key }.toSet())
            overlaps = askOverlaps()
            render()
            frameOnce()
            loadJob = null
            val due = if (opening) ReadDue.onOpen(sources.firstLoadPending, checkedAt, Instant.now()) else ReadDue.onReturn(sources.firstLoadPending)
            if (sources.healthConnect && readiness?.isReadable() == true && due) loadUpdates()
        }
    }

    /** Health Connect read now, and kept until the next read: on opening ([restore]) or Refresh.
     *  A failure keeps what was listed, and says why over the list. */
    private fun loadUpdates() {
        if (runJob != null || loading) return
        loadJob?.cancel()
        loadJob = scope().launch {
            loading = true
            render()
            try {
                when (val result = WaitingLoader(activity).load()) {
                    is WaitingLoader.Result.Loaded -> {
                        sessions = result.sessions
                        known = emptySet()
                        checkedAt = result.checkedAt
                        sourceProblem = result.refused.takeIf { it > 0 }?.let { res.getQuantityString(R.plurals.sync_routes_refused, it, it) }
                        hidden = hiddenStore().all()
                        ticked.retainAll(all().map { it.key }.toSet())
                        overlaps = askOverlaps()
                        framed = false
                    }
                    is WaitingLoader.Result.Failed -> sourceProblem = result.reason
                    WaitingLoader.Result.Unreadable -> readiness = HealthConnect.readiness(activity)
                }
            } finally {
                loading = false
                loadJob = null
            }
            render()
            frameOnce()
        }
        render()
    }

    /** The first time the tab has something to show, the camera frames all of it. */
    private fun frameOnce() {
        if (framed) return
        val all = drawn()
        if (all.isNotEmpty()) {
            framed = true
            onFrame(all)
        }
    }

    /** The account's track each listed row overlaps (`POST /v2/tracks/overlaps`). A hint
     *  only: when the server can't say, the rows go without it. */
    private suspend fun askOverlaps(): Map<String, TrackOverlap> {
        if (Session.isDemo) return emptyMap()
        return try {
            // What's on its way would only overlap itself once it lands.
            val listed = all().filterNot { SyncProgress.isProcessing(it.key) }
            HoldMyTrackApi.trackOverlaps(listed.map { OverlapSpan(it.key, it.startedAt, it.endedAt) })
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            emptyMap()
        }
    }

    private fun hiddenStore() = HiddenCandidates(activity, Session.email)

    private fun healthConnectOn() = SyncSources(activity, Session.email).healthConnect

    /** The tab's lists from its state now ([SyncList]). */
    private fun list(): SyncList =
        SyncList.of(sessions, known, recordings, hidden, showHidden, types, SyncProgress.candidates, ticked)

    private fun all(): List<Candidate> = list().everything

    private fun shown(): List<Candidate> = list().shown

    private fun processing(candidate: Candidate) = SyncProgress.isProcessing(candidate.key)

    private fun drawn(): List<Candidate> = list().drawn

    private fun sendable(): List<Candidate> = list().sendable

    private fun render() {
        if (!showing) return
        // Worked out once a pass: every list below is a view of it.
        val list = list()
        rendered = list
        TrackTypes.refresh(list.everything.map { it.trackType })
        val demo = Session.isDemo
        accountNotice.text = if (demo) res.getString(R.string.sync_demo_read_only) else null
        accountNotice.visibility = if (demo) View.VISIBLE else View.GONE
        upload.visibility = if (demo) View.GONE else View.VISIBLE

        val everything = list.everything
        val shown = list.shown
        renderTypes(everything)
        // Health Connect off, or on and not set up yet, is said here and set right in Settings ›
        // Sync; read, it's the window the list reaches back over, or what went wrong.
        val readable = readiness?.isReadable() == true
        val setUp = when {
            demo || readiness == null -> null
            !healthConnectOn() -> res.getString(R.string.sync_hc_is_off)
            !readable && readiness != HealthConnect.Readiness.UNAVAILABLE -> res.getString(R.string.sync_hc_needs_setup)
            else -> null
        }
        sourceNote.text = setUp ?: sourceProblem ?: res.getString(R.string.sync_window_note)
        sourceNote.setTextColor(activity.getColor(if (setUp == null && sourceProblem != null) R.color.hmt_danger else R.color.hmt_ink_meta))
        sourceNote.visibility = if (setUp != null || (!demo && readable)) View.VISIBLE else View.GONE
        sourceSettings.visibility = if (setUp != null) View.VISIBLE else View.GONE

        // Health Connect's row over that note: when it was last read, with Refresh.
        val healthConnect = !demo && healthConnectOn()
        val sourceLine = SyncSourceRow.line(healthConnect, readable, setUpNotice = setUp != null, loading, checkedAt)
        sourceRow.visibility = if (sourceLine == SyncSourceRow.Line.Hidden) View.GONE else View.VISIBLE
        sourceStatus.text = when (sourceLine) {
            SyncSourceRow.Line.Hidden -> null
            SyncSourceRow.Line.NotSetUp -> res.getString(R.string.sync_source_not_set_up)
            SyncSourceRow.Line.Reading -> res.getString(R.string.sync_loading_health_connect)
            SyncSourceRow.Line.NotRead -> res.getString(R.string.sync_hc_not_read)
            is SyncSourceRow.Line.Read -> res.getString(R.string.sync_hc_read, PanelFormat.phoneDateTime(res, sourceLine.at))
        }
        refresh.visibility = if (SyncSourceRow.refreshShown(sourceLine)) View.VISIBLE else View.GONE
        refresh.isEnabled = !loading && runJob == null

        // The recordings not sent yet, which send themselves; Retry sends them now.
        val unsent = RecordingSendRules.waiting(recordings.filterNot { processing(it) }.map { it.key }, hidden, demo)
        val sendingRecordings = recordings.any { RecordingSends.note(it.key, it.key in hidden) == RecordingSendRules.Note.Sending }
        recordingsRow.visibility = if (unsent > 0) View.VISIBLE else View.GONE
        recordingsStatus.text = if (sendingRecordings) {
            res.getString(R.string.sync_recordings_sending)
        } else {
            res.getQuantityString(R.plurals.sync_recordings_unsent, unsent, unsent)
        }
        recordingsRetry.isEnabled = !sendingRecordings

        val tickable = list.tickable
        filters.visibility = if (everything.isEmpty()) View.GONE else View.VISIBLE
        selectAll.visibility = if (tickable.isEmpty() || demo) View.GONE else View.VISIBLE
        selectAll.setText(if (tickable.isNotEmpty() && tickable.all { it.key in ticked }) R.string.sync_select_none else R.string.sync_select_all)

        // Rows that can still be sent: what's on its way or hidden isn't offered, so it isn't
        // anyone's double.
        if (list.offered != similarOf) {
            similar = Similar.waiting(list.offered)
            similarOf = list.offered
        }
        rows.submitList(shown.map { row(it) })
        listNote.text = when {
            loading && everything.isEmpty() -> res.getString(R.string.sync_list_loading)
            everything.isEmpty() && healthConnect && checkedAt == null -> res.getString(R.string.sync_list_not_loaded)
            everything.isEmpty() -> res.getString(R.string.sync_list_empty)
            else -> null
        }
        listNote.visibility = if (listNote.text.isNullOrEmpty()) View.GONE else View.VISIBLE
        val hiddenCount = everything.count { it.key in hidden }
        showHiddenButton.visibility = if (hiddenCount > 0 || showHidden) View.VISIBLE else View.GONE
        showHiddenButton.text = if (showHidden) res.getString(R.string.sync_hide_hidden) else res.getString(R.string.sync_show_hidden, hiddenCount)

        val sending = list.sendable
        val running = runJob != null
        // Add is there even with nothing listed, disabled, and with Upload beside it.
        bar.visibility = if (demo) View.GONE else View.VISIBLE
        progress.visibility = if (running || loading) View.VISIBLE else View.GONE
        // Two ticked copies of one walk: said in the bar, and still sent if the user goes on.
        val sendingKeys = sending.map { it.key }.toSet()
        val doubled = sending.count { c -> similar[c.key].orEmpty().any { it.key in sendingKeys } }
        tickedLine.text = if (doubled > 0) {
            res.getQuantityString(R.plurals.sync_ticked_similar, doubled, sending.size, tickable.size, doubled)
        } else {
            res.getString(
                R.string.sync_ticked,
                sending.size,
                tickable.size,
                PanelFormat.totalDistance(res, sending.sumOf { it.distanceM }),
            )
        }
        syncNow.isEnabled = !demo && !running && sending.isNotEmpty()

        onCandidates(shown.filterNot(::processing), highlight)
    }

    /** One chip per type listed, when there's more than one to choose between. */
    private fun renderTypes(everything: List<Candidate>) {
        val listedTypes = everything.map { it.trackType }.distinct().sortedBy { TrackTypes.label(it) }
        types.retainAll(listedTypes.toSet())
        typeChips.visibility = if (listedTypes.size > 1) View.VISIBLE else View.GONE
        val current = (0 until typeChips.childCount).map { typeChips.getChildAt(it).tag as String }
        if (current != listedTypes) {
            typeChips.removeAllViews()
            for (type in listedTypes) {
                val chip = LayoutInflater.from(activity).inflate(R.layout.item_sync_type_chip, typeChips, false) as Chip
                typeChips.addView(chip.apply {
                    tag = type
                    text = TrackTypes.label(type)
                    setOnCheckedChangeListener { _, checked ->
                        if (checked) types += type else types -= type
                        render()
                    }
                })
            }
        }
        for (i in 0 until typeChips.childCount) {
            val chip = typeChips.getChildAt(i) as Chip
            val checked = chip.tag in types
            if (chip.isChecked != checked) chip.isChecked = checked
        }
    }

    /** Ticks every row shown, or, when they all are, unticks them. */
    private fun toggleAll() {
        val tickable = list().tickable.map { it.key }
        if (tickable.all { it in ticked }) ticked -= tickable.toSet() else ticked += tickable
        render()
    }

    private fun toggle(key: String) {
        if (key in hidden || SyncProgress.isProcessing(key)) return
        if (!ticked.remove(key)) ticked += key
        render()
    }

    private fun pick(candidate: Candidate) {
        highlight = candidate.key
        render()
        onFrame(listOf(candidate))
        val index = rows.currentList.indexOfFirst { it.key == candidate.key }
        if (index >= 0) list.scrollToPosition(index + 1)
    }

    /** A row's ⓘ: what else covers its time. A waiting one is picked out here; one on the map
     *  opens there, on its day, as Sync history's View on map does. */
    private fun showSimilar(candidate: Candidate) {
        similarSheet?.dismiss()
        similarSheet = SimilarTracksSheet.show(
            activity,
            of = candidate,
            waiting = similar[candidate.key].orEmpty(),
            onMap = overlaps[candidate.key],
            onPick = ::pick,
            onOpen = { o ->
                val day = runCatching { OffsetDateTime.parse(o.startedAt).atZoneSameInstant(PanelFormat.zone(o.timezone)).toLocalDate().toString() }.getOrNull()
                if (day != null) MainActivity.viewOnMap(activity, o.id, day)
            },
        )
    }

    /** Delete's question while it's up. */
    private var deleteDialog: Dialog? = null

    /** Swiped aside: hidden, with Undo; a hidden one swiped is back on the list. */
    private fun swiped(key: String) {
        val store = hiddenStore()
        val wasHidden = key in hidden
        if (wasHidden) store.unhide(key) else store.hide(key)
        ticked -= key
        hidden = store.all()
        render()
        onWaitingChanged()
        Snackbar.make(list, if (wasHidden) R.string.sync_unhidden else R.string.sync_hidden, Snackbar.LENGTH_LONG)
            .apply { if (bar.visibility == View.VISIBLE) anchorView = bar }
            .setAction(R.string.sync_undo) {
                val again = hiddenStore()
                if (wasHidden) again.hide(key) else again.unhide(key)
                hidden = again.all()
                render()
                onWaitingChanged()
            }
            .show()
    }

    private fun confirmDelete(candidate: Candidate) {
        // A double tap: one question, so closing it is closing the hold.
        if (deleteDialog != null) return
        val app = activity.applicationContext
        var deleting: Job? = null
        RecordingSends.hold(candidate.key)
        deleteDialog = MaterialAlertDialogBuilder(activity, R.style.ThemeOverlay_HoldMyTrack_Dialog_Destructive)
            .setTitle(R.string.recorded_delete_confirm_title)
            .setMessage(R.string.recorded_delete_confirm_message)
            .setPositiveButton(R.string.recording_delete) { _, _ ->
                deleting = scope().launch {
                    val stored = store.header(candidate.externalId) != null
                    val refusal = RecordingSends.refusal(RecordingSends.deletion(candidate.key, stored))
                    if (refusal != null) {
                        render()
                        Snackbar.make(list, refusal, Snackbar.LENGTH_LONG)
                            .apply { if (bar.isVisible) anchorView = bar }
                            .show()
                        return@launch
                    }
                    store.delete(candidate.externalId)
                    hiddenStore().unhide(candidate.key)
                    hidden = hiddenStore().all()
                    recordings = recordings.filterNot { it.key == candidate.key }
                    ticked -= candidate.key
                    render()
                    onWaitingChanged()
                }
            }
            .setNegativeButton(android.R.string.cancel, null)
            .setOnDismissListener {
                deleteDialog = null
                // After the delete, if that was the answer, however it ended.
                deleting?.invokeOnCompletion { RecordingSends.release(app, candidate.key) } ?: RecordingSends.release(app, candidate.key)
            }
            .show()
    }

    /** Sends what's ticked (and shown) — nothing else. What lands leaves the list. */
    private fun startSync() {
        val sending = sendable()
        if (sending.isEmpty() || runJob != null) return
        loadJob?.cancel()
        loadJob = null
        loading = false
        results.visibility = View.GONE
        problems.visibility = View.GONE
        runJob = scope().launch {
            try {
                val report = SyncRunner(store, res, HealthConnect.clientOrNull(activity)).send(sending, ::landed) { sent ->
                    tickedLine.text = res.getString(R.string.sync_progress, sent, sending.size)
                }
                show(report)
                if (report.landed.isNotEmpty()) onSynced()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                showProblems(listOf(res.getString(R.string.sync_failed, FailureText.of(e, res.getString(R.string.something_went_wrong), res.getString(R.string.network_error)))))
            } finally {
                runJob = null
                render()
            }
        }
        render()
    }

    /** A batch the server has now is on its way to the map ([SyncProgress]): listed as that until
     *  it lands, no longer as something to tick — a session is known, a recording marked sent.
     *  Called as each batch lands, so a run cut short keeps what it sent. */
    private fun landed(batch: List<Candidate>) {
        val keys = batch.mapTo(HashSet()) { it.key }
        val landedSessions = batch.filter { it.source == HoldMyTrackApi.SOURCE_HEALTH_CONNECT }
        known = known + landedSessions.map { it.externalId }
        // The account has them: off the kept list too, or a restart would offer them again. Not
        // on the tab's scope, which a pause cancels.
        if (landedSessions.isNotEmpty()) SyncProgress.forget(waiting, landedSessions.map { it.key })
        recordings = recordings.filterNot { it.key in keys }
        ticked -= keys
        if (highlight in keys) highlight = null
        SyncProgress.add(activity, batch)
    }

    /** [SyncProgress] moved on. A failed one is offered again: a session no longer counts as
     *  known, and a recording is unsent in the store again, so the list is read again. */
    private fun progressed() {
        if (!showing) return
        if (showFailed()) {
            restore(opening = false)
            // The server's reason for it, and for any upload that failed meanwhile.
            ImportFailureAlert.check(activity)
        }
        render()
    }

    /** Says which sent rows failed since last asked — even while the tab was away — and
     *  whether any did. */
    private fun showFailed(): Boolean {
        val failed = SyncProgress.takeFailed()
        if (failed.isEmpty()) return false
        val format = DATE_FORMAT.withZone(ZoneId.systemDefault())
        val lines = failed.map { res.getString(R.string.sync_row_failed, format.format(it.startedAt), TrackTypes.label(it.trackType)) }
        val earlier = problems.text.takeIf { problems.visibility == View.VISIBLE && it.isNotEmpty() }?.toString()
        showProblems(listOfNotNull(earlier) + lines)
        known = known - failed.map { it.externalId }.toSet()
        keepAgain += failed.filter { it.source == HoldMyTrackApi.SOURCE_HEALTH_CONNECT }
        return true
    }

    /**
     * What the run did, and what it couldn't: the ones the server refused, each with the server's
     * own reason — they stay ticked on the list — and why it stopped early, if it did.
     */
    private fun show(report: SyncReport) {
        val sent = report.synced + report.alreadyPresent
        if (sent > 0) {
            results.text = if (report.alreadyPresent > 0) {
                res.getString(R.string.sync_summary_with_present, report.synced, report.alreadyPresent)
            } else {
                res.getQuantityString(R.plurals.sync_summary, report.synced, report.synced)
            }
            results.visibility = View.VISIBLE
        }
        val trouble = report.rejected.map {
            res.getString(R.string.sync_rejected_row, DATE_FORMAT.withZone(ZoneId.systemDefault()).format(it.startedAt), TrackTypes.label(it.trackType), it.reason)
        }.toMutableList()
        report.stoppedBecause?.let { trouble += res.getString(R.string.sync_stopped, it) }
        showProblems(trouble)
    }

    private fun showProblems(lines: List<String>) {
        problems.text = lines.joinToString("\n")
        problems.visibility = if (lines.isEmpty()) View.GONE else View.VISIBLE
    }

    private fun row(candidate: Candidate): SyncRow {
        val date = DATE_FORMAT.withZone(ZoneId.systemDefault()).format(candidate.startedAt)
        val named = candidate.name.isNotBlank()
        val meta = listOfNotNull(
            date.takeIf { named },
            PanelFormat.distance(res, candidate.distanceM),
            TrackTypes.label(candidate.trackType),
            res.getString(if (candidate.isRecording) R.string.sync_origin_recorded else R.string.sync_origin_health_connect),
        ).joinToString(" · ")
        val sendNote = if (candidate.isRecording) RecordingSends.note(candidate.key, candidate.key in hidden) else null
        val processing = processing(candidate) || sendNote == RecordingSendRules.Note.Sending
        val note = when {
            processing(candidate) || sendNote == RecordingSendRules.Note.Processing -> res.getString(R.string.sync_row_processing)
            sendNote == RecordingSendRules.Note.Sending -> res.getString(R.string.recording_note_sending)
            sendNote is RecordingSendRules.Note.Refused -> res.getString(R.string.recording_note_refused, sendNote.reason)
            sendNote == RecordingSendRules.Note.Waiting -> res.getString(R.string.recording_note_waiting)
            else -> null
        }
        val similarCount = if (processing) 0 else similar[candidate.key].orEmpty().size + (if (candidate.key in overlaps) 1 else 0)
        return SyncRow(
            key = candidate.key,
            title = if (named) candidate.name else date,
            meta = meta,
            note = note,
            processing = processing,
            similar = similarCount,
            type = candidate.trackType,
            recording = candidate.isRecording,
            ticked = candidate.key in ticked,
            hidden = candidate.key in hidden,
            highlighted = candidate.key == highlight,
        )
    }

    private fun candidate(key: String): Candidate? = (rendered ?: list()).everything.firstOrNull { it.key == key }

    /** A row swiped either way is hidden — or, a hidden one, back. The head and foot stay. */
    private inner class SwipeToHide : ItemTouchHelper.SimpleCallback(0, ItemTouchHelper.START or ItemTouchHelper.END) {
        override fun getSwipeDirs(recyclerView: RecyclerView, holder: RecyclerView.ViewHolder): Int =
            if (holder is SyncRowHolder && !holder.processing && runJob == null) super.getSwipeDirs(recyclerView, holder) else 0

        override fun onMove(recyclerView: RecyclerView, holder: RecyclerView.ViewHolder, target: RecyclerView.ViewHolder) = false

        override fun onSwiped(holder: RecyclerView.ViewHolder, direction: Int) {
            val key = (holder as SyncRowHolder).key ?: return
            swiped(key)
        }
    }

    /** One fixed view as a list's item — the head and the foot. */
    private class ViewAdapter(private val view: View) : RecyclerView.Adapter<RecyclerView.ViewHolder>() {
        override fun getItemCount() = 1
        override fun getItemViewType(position: Int) = System.identityHashCode(view)
        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) = object : RecyclerView.ViewHolder(view) {}
        override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) = Unit
    }

    private companion object {
        val DATE_FORMAT: DateTimeFormatter = DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT)
    }
}
