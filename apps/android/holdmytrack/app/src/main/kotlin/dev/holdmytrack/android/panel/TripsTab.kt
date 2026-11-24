package dev.holdmytrack.android.panel

import android.annotation.SuppressLint
import android.os.Handler
import android.os.Looper
import android.util.TypedValue
import android.view.GestureDetector
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.TableLayout
import android.widget.TableRow
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.widget.TooltipCompat
import androidx.recyclerview.widget.ConcatAdapter
import androidx.recyclerview.widget.DiffUtil
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.ListAdapter
import androidx.recyclerview.widget.RecyclerView
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import dev.holdmytrack.android.R
import dev.holdmytrack.android.net.ApiException
import dev.holdmytrack.android.net.FailureText
import dev.holdmytrack.android.net.HoldMyTrackApi
import dev.holdmytrack.android.net.Session
import dev.holdmytrack.android.net.Trip
import dev.holdmytrack.android.net.TripCopying
import dev.holdmytrack.android.net.TripSend
import dev.holdmytrack.android.net.TripTotals
import dev.holdmytrack.android.recording.RecordingTypes

/**
 * The Tracks panel's Trips tab, the web's `apps/web/src/ui/TripsTab.tsx` and the Trip
 * half of `MapView.tsx` (`docs/SPEC.md` FR-13.6): every Trip as a folder, newest first,
 * exactly one of them open while the tab shows — the newest, until another is tapped. Opening
 * one is viewing it: `MapFragment` shows the tracks and the list of all its tracks,
 * whatever the date range ([onOpen]), and this tab lists those rows inside the folder — tap to
 * select, × to take one out of the Trip — with the whole Trip's statistics in the footer. A tap
 * on the open Trip's folder folds its list away or back ([TripFold]); the Trip stays open. A
 * folder's pencil and bin rename and delete it, and its send button sends someone a copy
 * ([SendCopySheet], FR-13.7).
 *
 * The list is read each time the tab opens ([start]), so a Trip made or changed since —
 * Add to trip's included — is there; the open Trip is read on its own ([setOpen]) for the
 * footer's numbers. Above the Trips, the copies others sent wait to be accepted or declined,
 * read with the list and every few seconds while an accepted one is arriving.
 */
class TripsTab(
    private val content: View,
    /** Open [tripId] — tapped ([collapse]: the sheet goes down so its tracks can be seen), or
     *  the newest opening with the tab. */
    private val onOpen: (tripId: String, collapse: Boolean) -> Unit,
    /** Nothing left to open: the last Trip was deleted. */
    private val onClose: () -> Unit,
    private val onSelect: (trackId: String) -> Unit,
    private val onClearFocus: () -> Unit,
    /** A Trip renamed or deleted — the rows' Trip badges name it. */
    private val onBadgesChanged: () -> Unit,
    /** [trackId] was taken out of the open Trip: the list and the tracks are out of date. */
    private val onTrackRemoved: (trackId: String) -> Unit,
    /** A copy of a Trip someone sent has arrived: new tracks, and Fog coming. */
    private val onCopyArrived: () -> Unit,
    /** The inbox read: [waiting] copies others sent wait to be answered — the bar's badge. */
    private val onInboxRead: (waiting: Int) -> Unit,
) {
    private val context = content.context
    private val res = context.resources
    private val list: RecyclerView = content.findViewById(R.id.trips_list)
    private val stats: View = content.findViewById(R.id.trips_stats)
    private val statsLine: TextView = content.findViewById(R.id.trips_stats_line)
    private val types: TableLayout = content.findViewById(R.id.trips_types)
    private val adapter = ItemAdapter()

    private var showing = false
    private var trips: List<Trip> = emptyList()

    /** A list read since the tab last opened is in hand. */
    private var ready = false
    private var error: String? = null

    /** The open Trip's id, and the Trip as `GET /v2/trips/{id}` last answered. */
    var openId: String? = null
        private set
    private var openTrip: Trip? = null
    private var openError: String? = null

    /** The Trip whose list is folded ([TripFold]); the tab opens with none. */
    private var foldedId: String? = null

    /** The open Trip's rows, as the panel last drew them. */
    private var rows: List<TrackRowItem> = emptyList()
    private var rowsLoading = false
    private var rowsError: String? = null

    /** The last × that failed, with the server's reason — shown above the rows until the next
     *  one, or another Trip opening. */
    private var removeError: String? = null

    /** The inbox (FR-13.7): copies waiting, and accepted ones arriving. */
    private var sends: List<TripSend> = emptyList()
    private var copying: List<TripCopying> = emptyList()
    private var answering = false
    private var answerError: String? = null
    private val handler = Handler(Looper.getMainLooper())
    private val pollInbox = Runnable { loadInbox() }

    init {
        list.layoutManager = LinearLayoutManager(context)
        // In landscape the statistics are the list's last item, scrolling with the rows: pinned
        // under them, they left the rows a sliver of the sheet.
        list.adapter = if (res.getBoolean(R.bool.trips_stats_scroll)) {
            (stats.parent as ViewGroup).removeView(stats)
            ConcatAdapter(adapter, FooterAdapter(stats))
        } else {
            adapter
        }
        list.itemAnimator = null
        clearFocusOnEmptyTap()
    }

    /** The tab opened: the list read afresh, and the newest opened once it's in. */
    fun start() {
        showing = true
        ready = false
        foldedId = null
        error = null
        render()
        loadTrips()
        loadInbox()
    }

    private fun loadTrips() {
        HoldMyTrackApi.trips { result ->
            if (!showing) return@trips
            result.onSuccess { next ->
                trips = next
                ready = true
                openNewest()
            }.onFailure { error = FailureText.of(it, res.getString(R.string.trip_load_failed)) }
            render()
        }
    }

    /** The tab closed — `MapFragment` has closed its Trip. */
    fun stop() {
        showing = false
        handler.removeCallbacks(pollInbox)
    }

    /** The inbox read again; while a copy is arriving, again a few seconds later. A copy that
     *  has arrived since the last read brings the list and the map up to date. */
    private fun loadInbox() {
        handler.removeCallbacks(pollInbox)
        HoldMyTrackApi.tripSends { result ->
            if (!showing) return@tripSends
            // The inbox is an extra on the tab: a failed read leaves the last one shown.
            val inbox = result.getOrNull() ?: return@tripSends
            val arrived = inbox.copying.size < copying.size
            sends = inbox.sends
            copying = inbox.copying
            onInboxRead(sends.size)
            if (arrived) {
                loadTrips()
                onCopyArrived()
            }
            if (copying.isNotEmpty()) handler.postDelayed(pollInbox, COPYING_POLL_MS)
            render()
        }
    }

    private fun answer(send: TripSend, accept: Boolean) {
        if (answering) return
        answering = true
        answerError = null
        render()
        HoldMyTrackApi.answerTripSend(send.id, accept) { result ->
            answering = false
            result.onFailure { failure ->
                answerError = FailureText.of(failure, res.getString(R.string.trip_save_failed))
            }
            render()
            loadInbox()
        }
    }

    /** [id] is the open Trip now (or none): its own copy is read for the footer. */
    fun setOpen(id: String?) {
        if (id != openId) {
            openId = id
            openTrip = null
            removeError = null
        }
        openError = null
        render()
        if (id != null) reloadOpen()
    }

    /** The open Trip read again — after anything that changes its tracks' numbers. A
     *  reload keeps the numbers shown until the new copy lands. */
    fun reloadOpen() {
        val id = openId ?: return
        HoldMyTrackApi.trip(id) { result ->
            if (id != openId) return@trip
            result.onSuccess { trip ->
                openTrip = trip
                openError = null
                trips = trips.map { if (it.id == trip.id) trip else it }
            }.onFailure { failure ->
                openTrip = null
                openError = if (failure is ApiException && failure.code == 404) {
                    res.getString(R.string.trip_not_found)
                } else {
                    FailureText.of(failure, res.getString(R.string.trip_load_failed))
                }
            }
            render()
        }
    }

    /** The open Trip's rows, from the panel's own render. */
    fun setRows(next: List<TrackRowItem>, loading: Boolean, error: String?) {
        rows = next
        rowsLoading = loading
        rowsError = error
        render()
    }

    /** Centres [trackId]'s row in the list — a track tapped on the map — the list alone,
     *  never the sheet around it. */
    fun scrollToRow(trackId: String) {
        list.post {
            val position = adapter.currentList.indexOfFirst { it is Item.Row && it.row.track.id == trackId }
            if (position < 0) return@post
            val rowHeight = list.getChildAt(0)?.height ?: 0
            (list.layoutManager as LinearLayoutManager).scrollToPositionWithOffset(position, (list.height - rowHeight) / 2)
        }
    }

    /** One Trip is always open on the tab: the newest, until another is picked. */
    private fun openNewest() {
        if (!showing || openId != null) return
        trips.firstOrNull()?.let { onOpen(it.id, false) }
    }

    private fun render() {
        val items = ArrayList<Item>()
        sends.forEach { items += Item.Inbox(it, answering) }
        copying.forEachIndexed { i, copy -> items += Item.Copying(copy, i) }
        answerError?.let { items += Item.Note(it, failed = true) }
        val openListed = trips.any { it.id == openId }
        if (openError != null && !openListed) items += Item.Note(openError!!, failed = true)
        for (listed in trips) {
            val open = listed.id == openId
            // The open Trip's own copy is the fresher one.
            val trip = if (open && openTrip?.id == listed.id) openTrip!! else listed
            val expanded = open && !TripFold.isFolded(foldedId, openId)
            items += Item.Folder(trip, open, expanded)
            if (!expanded) continue
            trip.from?.let { items += Item.From(trip.id, res.getString(R.string.trip_from, it)) }
            if (trip.description.isNotEmpty()) items += Item.Description(trip.id, trip.description)
            removeError?.let { items += Item.Note(it, failed = true) }
            rows.forEach { items += Item.Row(it, trip.id) }
            when {
                rowsLoading -> items += Item.Note(res.getString(R.string.panel_loading), failed = false)
                rowsError != null -> items += Item.Note(rowsError!!, failed = true)
                rows.isEmpty() -> items += Item.Note(
                    res.getString(if (trip.stats.count == 0) R.string.trip_no_tracks else R.string.panel_none_match),
                    failed = false,
                )
            }
        }
        when {
            error != null -> items += Item.Note(error!!, failed = true)
            !ready && trips.isEmpty() -> items += Item.Note(res.getString(R.string.panel_loading), failed = false)
            ready && trips.isEmpty() -> items += Item.Note(res.getString(R.string.trip_empty), failed = false)
        }
        adapter.submitList(items)
        renderStats()
    }

    /** The whole Trip, whatever the date range selects (FR-13.1). */
    private fun renderStats() {
        val trip = openTrip?.takeIf { it.id == openId }
        stats.visibility = if (trip == null) View.GONE else View.VISIBLE
        types.removeAllViews()
        if (trip == null) return
        if (trip.stats.count == 0) {
            statsLine.setText(R.string.trip_no_tracks)
            return
        }
        statsLine.text = statsLine(trip.stats)
        val gap = res.getDimensionPixelSize(R.dimen.hmt_space_12)
        for (type in trip.byType) {
            val row = TableRow(context)
            row.addView(typeCell(TrackTypes.label(type.trackType)).apply { setPadding(0, 0, gap, 0) })
            row.addView(typeCell(statsLine(type)))
            types.addView(row)
        }
    }

    private fun typeCell(text: String) = TextView(context).apply {
        this.text = text
        setTextColor(context.getColor(R.color.hmt_ink_secondary))
        setTextSize(TypedValue.COMPLEX_UNIT_PX, res.getDimension(R.dimen.hmt_text_sm))
    }

    /** "3 tracks · 58 km · 3h 26m moving" — the Trip's, or one type's share of it. */
    private fun statsLine(totals: TripTotals): String = res.getString(
        R.string.trip_stats,
        res.getQuantityString(R.plurals.trip_track_count, totals.count, totals.count),
        PanelFormat.totalDistance(res, totals.distanceMeters),
        PanelFormat.duration(res, totals.movingSeconds),
    )

    private fun confirmDelete(trip: Trip) {
        val dialog = MaterialAlertDialogBuilder(context, R.style.ThemeOverlay_HoldMyTrack_Dialog_Destructive)
            .setTitle(R.string.trip_delete_title)
            .setMessage(res.getString(R.string.trip_delete_confirm, trip.name))
            .setPositiveButton(R.string.trip_delete_button, null)
            .setNegativeButton(android.R.string.cancel, null)
            .create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener { delete(dialog, trip) }
        }
        dialog.show()
    }

    /** The dialog stays up while it runs, and keeps a failure on screen with a retry. */
    private fun delete(dialog: AlertDialog, trip: Trip) {
        val confirm = dialog.getButton(AlertDialog.BUTTON_POSITIVE)
        val cancel = dialog.getButton(AlertDialog.BUTTON_NEGATIVE)
        dialog.setCancelable(false)
        confirm.isEnabled = false
        cancel.isEnabled = false
        confirm.setText(R.string.panel_deleting)
        HoldMyTrackApi.deleteTrip(trip.id) { result ->
            result.onSuccess {
                dialog.dismiss()
                deleted(trip.id)
            }.onFailure { failure ->
                dialog.setCancelable(true)
                confirm.isEnabled = true
                cancel.isEnabled = true
                confirm.setText(R.string.trip_delete_button)
                dialog.setMessage(res.getString(R.string.trip_delete_failed, FailureText.of(failure, res.getString(R.string.something_went_wrong), res.getString(R.string.network_error))))
            }
        }
    }

    /** Dropped from the list in hand rather than read again. Deleting the open Trip opens the
     *  next newest in its place; deleting the last leaves none open. */
    private fun deleted(id: String) {
        trips = trips.filter { it.id != id }
        onBadgesChanged()
        if (id != openId) {
            render()
            return
        }
        val next = trips.firstOrNull()
        if (next != null) onOpen(next.id, false) else onClose()
        render()
    }

    /** The row's ×: out of the Trip at once, with no confirmation — the track itself stays,
     *  and Add to trip puts it back (`docs/SPEC.md` FR-13.6). */
    private fun remove(tripId: String, trackId: String) {
        HoldMyTrackApi.changeTripTracks(tripId, listOf(trackId), add = false) { result ->
            result.onSuccess { trip ->
                removeError = null
                trips = trips.map { if (it.id == trip.id) trip else it }
                if (trip.id == openId) openTrip = trip
                onTrackRemoved(trackId)
            }.onFailure { failure ->
                removeError = FailureText.of(failure, res.getString(R.string.trip_save_failed))
            }
            render()
        }
    }

    private fun edited(trip: Trip) {
        trips = trips.map { if (it.id == trip.id) trip else it }
        if (trip.id == openId) openTrip = trip
        onBadgesChanged()
        render()
    }

    @SuppressLint("ClickableViewAccessibility") // A tap on no item at all; each item is its own target.
    private fun clearFocusOnEmptyTap() {
        val detector = GestureDetector(
            context,
            object : GestureDetector.SimpleOnGestureListener() {
                override fun onSingleTapUp(e: MotionEvent): Boolean {
                    if (list.findChildViewUnder(e.x, e.y) == null) onClearFocus()
                    return false
                }
            },
        )
        list.setOnTouchListener { _, event ->
            detector.onTouchEvent(event)
            false
        }
    }

    /** What the list draws, in order: folders, the open one's description and rows, notes. */
    private sealed class Item(val key: String) {
        data class Folder(val trip: Trip, val open: Boolean, val expanded: Boolean) : Item("folder:" + trip.id)
        data class Description(val tripId: String, val text: String) : Item("description:$tripId")
        data class From(val tripId: String, val text: String) : Item("from:$tripId")
        data class Inbox(val send: TripSend, val answering: Boolean) : Item("inbox:" + send.id)
        data class Copying(val copy: TripCopying, val index: Int) : Item("copying:$index")
        data class Row(val row: TrackRowItem, val tripId: String) : Item("row:" + row.track.id)
        data class Note(val text: String, val failed: Boolean) : Item("note:$text")
    }

    private inner class ItemAdapter : ListAdapter<Item, RecyclerView.ViewHolder>(
        object : DiffUtil.ItemCallback<Item>() {
            override fun areItemsTheSame(old: Item, new: Item) = old.key == new.key
            override fun areContentsTheSame(old: Item, new: Item) = old == new
        },
    ) {
        override fun getItemViewType(position: Int) = when (getItem(position)) {
            is Item.Folder -> TYPE_FOLDER
            is Item.Description, is Item.From -> TYPE_DESCRIPTION
            is Item.Inbox, is Item.Copying -> TYPE_INBOX
            is Item.Row -> TYPE_ROW
            is Item.Note -> TYPE_NOTE
        }

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RecyclerView.ViewHolder {
            val inflater = LayoutInflater.from(parent.context)
            return when (viewType) {
                TYPE_FOLDER -> FolderHolder(inflater.inflate(R.layout.item_trip_folder, parent, false))
                TYPE_DESCRIPTION -> object : RecyclerView.ViewHolder(inflater.inflate(R.layout.item_trip_description, parent, false)) {}
                TYPE_INBOX -> InboxHolder(inflater.inflate(R.layout.item_trip_inbox, parent, false))
                TYPE_ROW -> {
                    val view = inflater.inflate(R.layout.item_track_row, parent, false)
                    // Set in under the folder's name, which is what makes them its contents.
                    val indent = (ROW_INDENT_DP * res.displayMetrics.density).toInt()
                    view.setPaddingRelative(indent, view.paddingTop, view.paddingEnd, view.paddingBottom)
                    TrackRowHolder(view)
                }
                else -> object : RecyclerView.ViewHolder(inflater.inflate(R.layout.item_panel_note, parent, false)) {}
            }
        }

        override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {
            when (val item = getItem(position)) {
                is Item.Folder -> (holder as FolderHolder).bind(item)
                is Item.Description -> (holder.itemView as TextView).apply {
                    text = item.text
                    setTextSize(TypedValue.COMPLEX_UNIT_PX, res.getDimension(R.dimen.hmt_text_md))
                }
                // Who sent the copy, smaller, over the description (.trips-tab__from).
                is Item.From -> (holder.itemView as TextView).apply {
                    text = item.text
                    setTextSize(TypedValue.COMPLEX_UNIT_PX, res.getDimension(R.dimen.hmt_text_sm))
                }
                is Item.Inbox -> (holder as InboxHolder).bind(item)
                is Item.Copying -> (holder as InboxHolder).bind(item)
                // Badged only for the row's other Trips: every row here is in this one.
                is Item.Row -> (holder as TrackRowHolder).bind(
                    item.row,
                    item.tripId,
                    onCheck = null,
                    onSelect = onSelect,
                    onOpenTrip = { id -> onOpen(id, true) },
                    onRemove = { trackId -> remove(item.tripId, trackId) },
                )
                is Item.Note -> (holder.itemView as TextView).apply {
                    text = item.text
                    setTextColor(context.getColor(if (item.failed) R.color.hmt_danger else R.color.panel_ink_50))
                    setOnClickListener { onClearFocus() }
                }
            }
        }
    }

    private inner class InboxHolder(view: View) : RecyclerView.ViewHolder(view) {
        private val text: TextView = view.findViewById(R.id.trip_inbox_text)
        private val actions: View = view.findViewById(R.id.trip_inbox_actions)
        private val accept: Button = view.findViewById(R.id.trip_inbox_accept)
        private val decline: Button = view.findViewById(R.id.trip_inbox_decline)

        fun bind(item: Item.Inbox) {
            val send = item.send
            text.text = res.getString(
                R.string.trip_inbox_sent,
                send.from,
                send.tripName,
                res.getQuantityString(R.plurals.trip_track_count, send.trackCount, send.trackCount),
            )
            text.setTextColor(context.getColor(R.color.hmt_ink))
            actions.visibility = View.VISIBLE
            accept.isEnabled = !item.answering
            decline.isEnabled = !item.answering
            accept.setOnClickListener { answer(send, true) }
            decline.setOnClickListener { answer(send, false) }
        }

        fun bind(item: Item.Copying) {
            text.text = res.getString(R.string.trip_inbox_copying, item.copy.tripName, item.copy.from)
            text.setTextColor(context.getColor(R.color.hmt_ink_secondary))
            actions.visibility = View.GONE
        }
    }

    private inner class FolderHolder(view: View) : RecyclerView.ViewHolder(view) {
        private val toggle: View = view.findViewById(R.id.trip_toggle)
        private val chevron: ImageView = view.findViewById(R.id.trip_chevron)
        private val name: TextView = view.findViewById(R.id.trip_name)
        private val edit: ImageButton = view.findViewById(R.id.trip_edit)
        private val send: ImageButton = view.findViewById(R.id.trip_send)
        private val delete: ImageButton = view.findViewById(R.id.trip_delete)

        fun bind(item: Item.Folder) {
            val trip = item.trip
            name.text = trip.name
            // The triangle points down while the list shows and right while folded; the accent,
            // and the row's tint (bg_trip_folder), mark the open Trip, folded or not.
            chevron.rotation = if (item.expanded) 90f else 0f
            chevron.setColorFilter(context.getColor(if (item.open) R.color.hmt_accent_strong else R.color.hmt_ink_meta))
            itemView.isSelected = item.open
            // setSelected reaches every child; TalkBack would call the actions "selected".
            listOf(edit, send, delete).forEach { it.isSelected = false }
            toggle.contentDescription = trip.name
            toggle.stateDescription = res.getString(if (item.expanded) R.string.trip_open else R.string.trip_folded)
            // A fold leaves the sheet where it is; opening another Trip lowers it.
            toggle.setOnClickListener {
                val click = TripFold.folderClick(foldedId, openId, trip.id)
                foldedId = click.foldedId
                if (click.open) onOpen(trip.id, true) else render()
            }

            // The demo account sees both, disabled, saying why (FR-13.6), as it does
            // the rows' ×.
            val demo = Session.isDemo
            val editLabel = res.getString(if (demo) R.string.trip_demo_edit else R.string.trip_edit)
            val deleteLabel = res.getString(if (demo) R.string.trip_demo_delete else R.string.trip_delete)
            val sendLabel = res.getString(if (demo) R.string.trip_demo_send else R.string.trip_send)
            edit.isEnabled = !demo
            send.isEnabled = !demo
            delete.isEnabled = !demo
            edit.contentDescription = "$editLabel: ${trip.name}"
            send.contentDescription = "$sendLabel: ${trip.name}"
            delete.contentDescription = "$deleteLabel: ${trip.name}"
            TooltipCompat.setTooltipText(edit, editLabel)
            TooltipCompat.setTooltipText(send, sendLabel)
            TooltipCompat.setTooltipText(delete, deleteLabel)
            edit.setOnClickListener { TripSheet.edit(context, trip, ::edited) }
            send.setOnClickListener { SendCopySheet.show(context, trip) }
            delete.setOnClickListener { confirmDelete(trip) }
        }
    }

    private companion object {
        const val TYPE_FOLDER = 0
        const val TYPE_DESCRIPTION = 1
        const val TYPE_ROW = 2
        const val TYPE_NOTE = 3
        const val TYPE_INBOX = 4

        /** How often the inbox is read again while an accepted copy is arriving. */
        const val COPYING_POLL_MS = 3000L

        /** The web's 36px `.trips-tab__rows` indent. */
        const val ROW_INDENT_DP = 36
    }
}

/** One view, always the list's last item: the open Trip's statistics in landscape ([TripsTab]). */
private class FooterAdapter(private val view: View) : RecyclerView.Adapter<RecyclerView.ViewHolder>() {
    override fun getItemCount() = 1

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RecyclerView.ViewHolder {
        view.layoutParams = RecyclerView.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        return object : RecyclerView.ViewHolder(view) {}
    }

    override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) = Unit
}
