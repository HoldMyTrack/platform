package dev.holdmytrack.android.panel

import android.annotation.SuppressLint
import android.os.Handler
import android.os.Looper
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.ImageButton
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.core.widget.doAfterTextChanged
import androidx.fragment.app.Fragment
import androidx.recyclerview.widget.DiffUtil
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.ListAdapter
import androidx.recyclerview.widget.RecyclerView
import com.google.android.material.button.MaterialButton
import com.google.android.material.chip.Chip
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.android.material.slider.RangeSlider
import dev.holdmytrack.android.R
import dev.holdmytrack.android.map.DateFilter
import dev.holdmytrack.android.map.DatesSheet
import dev.holdmytrack.android.net.FailureText
import dev.holdmytrack.android.net.HoldMyTrackApi
import dev.holdmytrack.android.net.Session
import dev.holdmytrack.android.net.Track
import dev.holdmytrack.android.net.TrackPage
import dev.holdmytrack.android.net.Trip
import java.time.OffsetDateTime
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlin.coroutines.cancellation.CancellationException

/**
 * The Library tab (`apps/android/docs/SPEC.md` FR-4.1, root `docs/SPEC.md` FR-17.1): every track
 * the account keeps, a page of 100 at a time, not tied to the map's area. The search, the sort
 * and the Type, Dates, Distance and Trip filters ask the server for the page ([LibraryRules]);
 * the rows are the Tracks tab's. A row's tap opens it on the map ([onOpen]); its tile, or a long
 * press, checks it, and the Checked tracks, which stay within the page, can be downloaded or
 * deleted. The + beside the search opens Sync, how more tracks come in ([onSync]).
 */
class LibraryTab(
    private val content: View,
    private val fragment: Fragment,
    /** The scope pages are read in: the map's view's, so they end with it. */
    private val scope: () -> CoroutineScope,
    private val download: TrackDownload,
    /** A row was tapped: the map shows it. */
    private val onOpen: (Track) -> Unit,
    /** Tracks were deleted: the map and the other lists are out of date. */
    private val onDeleted: (List<String>) -> Unit,
    /** Sync was tapped: the Sync sheet opens over this one. */
    private val onSync: () -> Unit,
    /** The tab came to the front: the recordings waiting are counted again ([setSyncWaiting]). */
    private val onShown: () -> Unit,
) {
    private val context = content.context
    private val res = context.resources

    private val search: TextView = content.findViewById(R.id.library_search)
    private val syncButton: MaterialButton = content.findViewById(R.id.library_sync)
    private val sortChip: Chip = content.findViewById(R.id.library_sort)
    private val typeChip: Chip = content.findViewById(R.id.library_type)
    private val datesChip: Chip = content.findViewById(R.id.library_dates)
    private val distanceChip: Chip = content.findViewById(R.id.library_distance)
    private val tripChip: Chip = content.findViewById(R.id.library_trip)
    private val resetChip: Chip = content.findViewById(R.id.library_reset)
    private val count: TextView = content.findViewById(R.id.library_count)
    private val bar: View = content.findViewById(R.id.library_bar)
    private val checkedLine: TextView = content.findViewById(R.id.library_checked)
    private val downloadButton: ImageButton = content.findViewById(R.id.library_download)
    private val deleteButton: ImageButton = content.findViewById(R.id.library_delete)
    private val progress: View = content.findViewById(R.id.library_progress)
    private val empty: TextView = content.findViewById(R.id.library_empty)
    private val firstPage: View = content.findViewById(R.id.library_first_page)
    private val list: RecyclerView = content.findViewById(R.id.library_list)
    private val pagerRow: View = content.findViewById(R.id.library_pager)
    private val range: TextView = content.findViewById(R.id.library_range)
    private val prev: ImageButton = content.findViewById(R.id.library_prev)
    private val next: ImageButton = content.findViewById(R.id.library_next)

    private val adapter = RowAdapter()
    private val handler = Handler(Looper.getMainLooper())

    private var state = LibraryRules.State()
    private var page: TrackPage? = null
    private var checked: Set<String> = emptySet()
    private var trips: List<Trip> = emptyList()
    private var failed: String? = null
    private var reading: Job? = null
    private var showing = false

    /** The map's view is gone: a late search or delete reads nothing, since [scope] is gone too. */
    private var destroyed = false

    private val dates = DatesSheet(
        fragment,
        onChange = { end, value -> setDates(DateFilter(state.after, state.before).setting(end, value, dateBounds()).filter) },
        onClear = { setDates(DateFilter.ALL_TIME) },
    )

    private val searchSoon = Runnable { change { copy(q = search.text.toString().trim()) } }

    init {
        list.layoutManager = LinearLayoutManager(context)
        list.adapter = adapter
        search.doAfterTextChanged {
            handler.removeCallbacks(searchSoon)
            handler.postDelayed(searchSoon, SEARCH_DELAY_MS)
        }
        syncButton.setOnClickListener { onSync() }
        sortChip.setOnClickListener { showSort() }
        typeChip.setOnClickListener { showTypes() }
        datesChip.setOnClickListener { showDates() }
        distanceChip.setOnClickListener { showDistance() }
        tripChip.setOnClickListener { showTrips() }
        resetChip.setOnClickListener {
            search.text = ""
            handler.removeCallbacks(searchSoon)
            change { LibraryRules.State(sort = sort, desc = desc) }
        }
        content.findViewById<View>(R.id.library_uncheck).setOnClickListener { setChecked(emptySet()) }
        downloadButton.setOnClickListener { downloadChecked() }
        deleteButton.setOnClickListener { confirmDelete() }
        firstPage.setOnClickListener { goTo(1) }
        prev.setOnClickListener { goTo(state.page - 1) }
        next.setOnClickListener { goTo(state.page + 1) }
    }

    /** The tab came to the front: the page is read again, since tracks may have come or gone. */
    fun start() {
        showing = true
        read()
        onShown()
        HoldMyTrackApi.trips { result -> result.onSuccess { trips = it; render() } }
    }

    /** Tracks came: the page is read again while it shows, unless rows are checked, which a read
     *  would clear. A failed read leaves the page as it was. */
    fun refresh() {
        // Nor while a read the user asked for is out: it would be cancelled, and its failure lost.
        if (showing && checked.isEmpty() && reading?.isActive != true) read(quiet = true)
    }

    fun stop() {
        showing = false
        dates.dismiss()
    }

    /** The map's view is being destroyed: the search waiting to be read goes, and nothing reads after. */
    fun destroy() {
        destroyed = true
        handler.removeCallbacks(searchSoon)
        reading?.cancel()
    }

    /** Sync's count: the recordings on this phone waiting to be sent, as the bar's Library badge
     *  counts them. */
    fun setSyncWaiting(waiting: Int) {
        syncButton.text = if (waiting > 0) waiting.toString() else ""
        syncButton.iconPadding = if (waiting > 0) res.getDimensionPixelSize(R.dimen.hmt_space_6) else 0
        syncButton.contentDescription = if (waiting > 0) {
            res.getQuantityString(R.plurals.library_sync_waiting, waiting, waiting)
        } else {
            res.getString(R.string.library_add)
        }
    }

    private fun change(block: LibraryRules.State.() -> LibraryRules.State) {
        val next = state.withFilter(block)
        if (next == state) return
        state = next
        read()
    }

    private fun goTo(page: Int) {
        state = state.copy(page = page)
        read()
    }

    private fun setChecked(next: Set<String>) {
        checked = next
        render()
    }

    /** Reads the page [state] asks for; a newer read replaces one under way. */
    private fun read(quiet: Boolean = false) {
        if (destroyed) return
        reading?.cancel()
        // Checked stays within the page: changing page, sort or filter clears it.
        checked = emptySet()
        val allTypes = page?.types?.map { it.first }.orEmpty()
        val query = LibraryRules.pageQuery(state, allTypes)
        if (query == null) {
            // Every type left out matches nothing: no need to ask.
            page = page?.copy(tracks = emptyList(), total = 0)
            failed = null
            // A read this one replaced was cancelled before it could hide its spinner.
            progress.visibility = View.GONE
            render()
            return
        }
        progress.visibility = View.VISIBLE
        reading = scope().launch {
            try {
                page = HoldMyTrackApi.trackPage(query)
                failed = null
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (!quiet) failed = FailureText.of(e, res.getString(R.string.something_went_wrong), res.getString(R.string.network_error))
            }
            progress.visibility = View.GONE
            render()
        }
    }

    private fun render() {
        val page = page
        sortChip.text = res.getString(sortLabel(state.sort, state.desc))
        mark(typeChip, state.exclude.isNotEmpty())
        mark(datesChip, state.after != null || state.before != null)
        mark(distanceChip, state.distance != null)
        mark(tripChip, state.trip != null)
        tripChip.text = state.trip?.let { id -> trips.firstOrNull { it.id == id }?.name } ?: res.getString(R.string.library_trip)
        distanceChip.visibility = if (page?.distance?.let { it.first < it.second } == true) View.VISIBLE else View.GONE
        resetChip.visibility = if (state.anyFilter) View.VISIBLE else View.GONE

        val rows = page?.tracks.orEmpty()
        val accountTotal = page?.types?.sumOf { it.second } ?: 0
        count.text = when {
            page == null -> ""
            state.anyFilter -> res.getQuantityString(R.plurals.library_count_filtered, accountTotal, page.total, accountTotal)
            else -> res.getQuantityString(R.plurals.library_count, page.total, page.total)
        }

        val pager = page?.let { LibraryRules.pager(state.page, it.total, it.pageSize) }
        pagerRow.visibility = if (pager != null && (pager.prev || pager.next)) View.VISIBLE else View.GONE
        if (pager != null && page != null) {
            range.text = res.getString(R.string.library_range, pager.from, pager.to, page.total)
            prev.isEnabled = pager.prev
            next.isEnabled = pager.next
        }

        empty.visibility = if (page != null && rows.isEmpty() || failed != null) View.VISIBLE else View.GONE
        empty.text = failed?.let { res.getString(R.string.library_failed, it) } ?: page?.let { emptyText(it) }
        firstPage.visibility = if (failed == null && page != null && rows.isEmpty() &&
            LibraryRules.emptyReason(state, page.total, page.types.isNotEmpty()) == LibraryRules.EmptyReason.PAST_LAST
        ) View.VISIBLE else View.GONE

        checked = LibraryRules.keepListed(checked, rows.map { it.id })
        bar.visibility = if (checked.isNotEmpty()) View.VISIBLE else View.GONE
        checkedLine.text = res.getQuantityString(R.plurals.panel_checked_count, checked.size, checked.size)
        val demo = Session.isDemo
        deleteButton.visibility = if (demo) View.GONE else View.VISIBLE
        deleteButton.isEnabled = rows.none { it.id in checked && it.pending }
        adapter.submitList(rows.map { TrackRowItem(it, checked = it.id in checked, focused = false, hidden = false, selecting = checked.isNotEmpty()) })
    }

    /** A chip's set look: filled while its filter is on. */
    private fun mark(chip: Chip, on: Boolean) {
        chip.isCheckable = true
        chip.isChecked = on
        chip.isCheckable = false
    }

    private fun emptyText(page: TrackPage): String {
        val anyTrack = page.types.isNotEmpty()
        return when (LibraryRules.emptyReason(state, page.total, anyTrack)) {
            LibraryRules.EmptyReason.NO_TRACKS -> res.getString(R.string.library_empty_no_tracks)
            LibraryRules.EmptyReason.PAST_LAST -> res.getString(R.string.library_empty_past_last)
            LibraryRules.EmptyReason.SEARCH -> res.getString(R.string.library_empty_search, state.q)
            LibraryRules.EmptyReason.SEARCH_AND_FILTERS -> res.getString(R.string.library_empty_search_and_filters, state.q)
            LibraryRules.EmptyReason.FILTERS -> res.getString(R.string.library_empty_filters)
        }
    }

    private fun showSort() {
        val options = SORTS
        val current = options.indexOfFirst { it.first == state.sort && it.second == state.desc }
        MaterialAlertDialogBuilder(context)
            .setTitle(R.string.library_sort_title)
            .setSingleChoiceItems(options.map { res.getString(sortLabel(it.first, it.second)) }.toTypedArray(), current) { dialog, which ->
                dialog.dismiss()
                change { copy(sort = options[which].first, desc = options[which].second) }
            }
            .show()
    }

    private fun showTypes() {
        val types = page?.types.orEmpty()
        if (types.isEmpty()) return
        val keep = BooleanArray(types.size) { types[it].first !in state.exclude }
        MaterialAlertDialogBuilder(context)
            .setTitle(R.string.panel_type)
            .setMultiChoiceItems(types.map { "${TrackTypes.label(it.first)} (${it.second})" }.toTypedArray(), keep) { _, which, on -> keep[which] = on }
            .setPositiveButton(android.R.string.ok) { _, _ ->
                change { copy(exclude = types.filterIndexed { i, _ -> !keep[i] }.map { it.first }.toSet()) }
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    private fun dateBounds(): DateFilter.Bounds =
        DateFilter.bounds(page?.firstDate, page?.lastDate, DateFilter.today(Session.timezone))

    private fun showDates() {
        dates.show(DateFilter(state.after, state.before), dateBounds(), page?.firstDate, DateFilter.today(Session.timezone))
    }

    private fun setDates(next: DateFilter) {
        dates.update(next)
        change { copy(after = next.after, before = next.before) }
    }

    @SuppressLint("InflateParams") // A dialog's content has no parent to inflate against.
    private fun showDistance() {
        val (min, max) = page?.distance ?: return
        val bounds = DistanceRange(min, max)
        val view = LayoutInflater.from(context).inflate(R.layout.dialog_library_distance, null)
        val slider: RangeSlider = view.findViewById(R.id.library_distance_slider)
        val readout: TextView = view.findViewById(R.id.library_distance_readout)
        val current = state.distance?.let { sliderRange(it, bounds) } ?: bounds
        slider.valueFrom = min.toFloat()
        slider.valueTo = max.toFloat()
        slider.values = listOf(current.min.toFloat(), current.max.toFloat())
        var chosen: DistanceRange? = state.distance?.let { current }
        fun show() {
            val band = chosen ?: bounds
            readout.text = res.getString(R.string.library_distance_band, PanelFormat.distance(res, band.min), PanelFormat.distance(res, band.max))
        }
        slider.addOnChangeListener { s, _, fromUser ->
            if (!fromUser) return@addOnChangeListener
            val lower = TrackFacets.nextDistanceFilter(bounds, chosen ?: bounds, DistanceKnob.MIN, s.values[0].toDouble())
            chosen = TrackFacets.nextDistanceFilter(bounds, lower ?: bounds, DistanceKnob.MAX, s.values[1].toDouble())
            show()
        }
        show()
        MaterialAlertDialogBuilder(context)
            .setTitle(R.string.panel_distance)
            .setView(view)
            .setPositiveButton(android.R.string.ok) { _, _ ->
                change { copy(distance = chosen?.let { LibraryRules.Distance(it.min, it.max) }) }
            }
            .setNeutralButton(R.string.panel_any_distance_chip) { _, _ -> change { copy(distance = null) } }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    private fun showTrips() {
        val names = listOf(res.getString(R.string.library_any_trip)) + trips.map { it.name }
        val current = state.trip?.let { id -> trips.indexOfFirst { it.id == id } + 1 } ?: 0
        MaterialAlertDialogBuilder(context)
            .setTitle(R.string.library_trip)
            .setSingleChoiceItems(names.toTypedArray(), current) { dialog, which ->
                dialog.dismiss()
                change { copy(trip = if (which == 0) null else trips[which - 1].id) }
            }
            .show()
    }

    private fun downloadChecked() {
        val rows = page?.tracks.orEmpty().filter { it.id in checked }
        val blocked = rows.firstOrNull { it.routeEdit in BLOCKED }
        if (blocked != null) {
            val reason = res.getString(
                when (blocked.routeEdit) {
                    "pending" -> R.string.library_blocked_pending
                    "private" -> R.string.library_blocked_private
                    else -> R.string.library_blocked_no_original
                },
            )
            Toast.makeText(context, res.getString(R.string.library_download_blocked, PanelFormat.rowLabel(res, blocked), reason), Toast.LENGTH_LONG).show()
            return
        }
        download.start(rows.map { it.id })
    }

    private fun confirmDelete() {
        val rows = page?.tracks.orEmpty().filter { it.id in checked }
        if (rows.isEmpty() || Session.isDemo) return
        val one = rows.size == 1
        val summary = res.getString(
            R.string.panel_group_summary,
            if (one) PanelFormat.rowLabel(res, rows[0]) else res.getQuantityString(R.plurals.panel_checked_count, rows.size, rows.size),
            PanelFormat.totalDistance(res, rows.sumOf { it.distanceMeters ?: 0.0 }),
        )
        val dialog = MaterialAlertDialogBuilder(context, R.style.ThemeOverlay_HoldMyTrack_Dialog_Destructive)
            .setTitle(if (one) R.string.panel_delete_one_title else R.string.panel_delete_title)
            .setMessage(res.getString(if (one) R.string.panel_delete_one_body else R.string.panel_delete_many_body, summary))
            .setPositiveButton(R.string.panel_delete_confirm, null)
            .setNegativeButton(android.R.string.cancel, null)
            .create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener { deleteNext(dialog, rows.map { it.id }, 0) }
        }
        dialog.show()
    }

    /** Deletes [ids] one after another, as the Tracks tab's Delete does. */
    private fun deleteNext(dialog: AlertDialog, ids: List<String>, index: Int) {
        val confirm = dialog.getButton(AlertDialog.BUTTON_POSITIVE)
        val cancel = dialog.getButton(AlertDialog.BUTTON_NEGATIVE)
        if (index == ids.size) {
            dialog.dismiss()
            onDeleted(ids)
            read()
            return
        }
        dialog.setCancelable(false)
        confirm.isEnabled = false
        cancel.isEnabled = false
        confirm.setText(R.string.panel_deleting)
        HoldMyTrackApi.deleteTrack(ids[index]) { result ->
            result.onSuccess { deleteNext(dialog, ids, index + 1) }
                .onFailure { failure ->
                    if (index > 0) {
                        onDeleted(ids.take(index))
                        if (showing) read()
                    }
                    dialog.setCancelable(true)
                    confirm.isEnabled = true
                    cancel.isEnabled = true
                    confirm.setText(R.string.panel_delete_confirm)
                    dialog.setMessage(res.getString(R.string.panel_delete_failed, FailureText.of(failure, res.getString(R.string.something_went_wrong), res.getString(R.string.network_error))))
                    confirm.setOnClickListener { deleteNext(dialog, ids, index) }
                }
        }
    }

    private fun toggle(id: String) = setChecked(if (id in checked) checked - id else checked + id)

    private inner class RowAdapter : ListAdapter<TrackRowItem, TrackRowHolder>(DIFF) {
        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) =
            TrackRowHolder(LayoutInflater.from(parent.context).inflate(R.layout.item_track_row, parent, false))

        override fun onBindViewHolder(holder: TrackRowHolder, position: Int) {
            val row = getItem(position)
            holder.bind(
                row,
                openTripId = null,
                onCheck = ::toggle,
                // While rows are checked, a tap checks too, as on the Tracks tab.
                onSelect = { id -> if (checked.isNotEmpty()) toggle(id) else page?.tracks?.firstOrNull { it.id == id }?.let(onOpen) },
                onOpenTrip = { id -> change { copy(trip = id) } },
            )
        }
    }

    companion object {
        private const val SEARCH_DELAY_MS = 300L

        /** A Distance filter's knobs on the account's [bounds], which may have shrunk under it since
         *  it was set: each inside them, the lower never past the upper, as the slider demands. */
        internal fun sliderRange(filter: LibraryRules.Distance, bounds: DistanceRange): DistanceRange {
            val low = filter.min.coerceIn(bounds.min, bounds.max)
            val high = (filter.max ?: bounds.max).coerceIn(bounds.min, bounds.max)
            return DistanceRange(low, high.coerceAtLeast(low))
        }

        /** Why a track can't be downloaded, as `route_edit` says it. */
        private val BLOCKED = setOf("pending", "private", "no_original")

        /** The sorts in the order Sort offers them. */
        private val SORTS = listOf(
            LibraryRules.Sort.STARTED to true, LibraryRules.Sort.STARTED to false,
            LibraryRules.Sort.DISTANCE to true, LibraryRules.Sort.DISTANCE to false,
            LibraryRules.Sort.MOVING to true, LibraryRules.Sort.MOVING to false,
            LibraryRules.Sort.ADDED to true, LibraryRules.Sort.ADDED to false,
        )

        private fun sortLabel(sort: LibraryRules.Sort, desc: Boolean): Int = when (sort) {
            LibraryRules.Sort.STARTED -> if (desc) R.string.library_sort_started_desc else R.string.library_sort_started_asc
            LibraryRules.Sort.DISTANCE -> if (desc) R.string.library_sort_distance_desc else R.string.library_sort_distance_asc
            LibraryRules.Sort.MOVING -> if (desc) R.string.library_sort_moving_desc else R.string.library_sort_moving_asc
            LibraryRules.Sort.ADDED -> if (desc) R.string.library_sort_added_desc else R.string.library_sort_added_asc
        }

        private val DIFF = object : DiffUtil.ItemCallback<TrackRowItem>() {
            override fun areItemsTheSame(a: TrackRowItem, b: TrackRowItem) = a.track.id == b.track.id
            override fun areContentsTheSame(a: TrackRowItem, b: TrackRowItem) = a == b
        }

        /** A track's own local day, where it was recorded: what the map's View on map takes. */
        fun day(track: Track): String =
            runCatching { OffsetDateTime.parse(track.startedAt).atZoneSameInstant(TrackZone.of(track.timezone, Session.timezone)).toLocalDate().toString() }
                .getOrDefault(track.startedAt.take(10))
    }
}
