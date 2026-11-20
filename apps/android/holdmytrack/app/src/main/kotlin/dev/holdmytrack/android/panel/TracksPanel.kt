package dev.holdmytrack.android.panel

import android.annotation.SuppressLint
import android.view.GestureDetector
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import android.content.res.ColorStateList
import android.graphics.Color
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.PopupMenu
import android.widget.TextView
import androidx.appcompat.widget.TooltipCompat
import androidx.recyclerview.widget.ConcatAdapter
import androidx.recyclerview.widget.DiffUtil
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.ListAdapter
import androidx.recyclerview.widget.RecyclerView
import androidx.appcompat.app.AlertDialog
import com.google.android.material.bottomsheet.BottomSheetBehavior
import com.google.android.material.button.MaterialButton
import com.google.android.material.checkbox.MaterialCheckBox
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import dev.holdmytrack.android.R
import dev.holdmytrack.android.net.FailureText
import dev.holdmytrack.android.net.Track
import dev.holdmytrack.android.net.HoldMyTrackApi
import dev.holdmytrack.android.net.Session
import dev.holdmytrack.android.net.Trip
import dev.holdmytrack.android.recording.RecordingTypes
import dev.holdmytrack.android.ui.LargeText

/** The panel's tabs: the web's `PanelTab`, and the bottom bar's Sync. */
enum class PanelTab { TRACKS, TRIPS, SYNC }

/**
 * The map's Tracks sheet (`apps/web/src/ui/TracksPanel.tsx`, redrawn for a phone): a
 * bottom sheet dragged between collapsed — its head alone — half the map and nearly all of it
 * (`BottomSheetBehavior`), a tap on its handle opening it halfway or closing it. On the
 * Tracks tab its head is the listed tracks' totals ([render]), the visible area's under
 * Dates (`map/AreaController`), and under it the Type, Dates and DISTANCE filters,
 * a toolbar over the toolbar's target, the rows and the target's summary. The Trips tab — the
 * bottom bar's Trips — has the account's Trips with one open on the map ([TripsTab]),
 * headed by its title instead of the totals; the Sync tab — the bottom bar's Sync — what's on
 * this phone waiting to be added ([SyncTab]), headed the same way.
 *
 * The rules live in [PanelState]; this draws it and turns taps into state changes.
 * `MapFragment` owns the map and the fetch: it hands over each list ([setTracks]) and
 * hears about every change that touches the map through [onMapChanged] (what to hide, what's
 * selected) and [onFly] (the tracks to frame); Edit is [onEdit]'s to open, and a finished
 * Delete is reported through [onDeleted]. Which Trip is open is `MapFragment`'s too
 * ([onOpenTrip], [onCloseTrip]): it narrows the map and the list, which this then draws.
 */
class TracksPanel(
    private val sheet: View,
    /** The selection bar over the map — the toolbar while the rows are being checked. */
    selectionBar: View,
    private val state: PanelState,
    private val onMapChanged: () -> Unit,
    private val onFly: (List<Track>) -> Unit,
    private val onEdit: (List<Track>) -> Unit,
    /** Every id the toolbar's Delete removed — the map, the list and the footer need
     *  fetching again. */
    private val onDeleted: (List<String>) -> Unit,
    /** The tab changed — leaving the Trips tab closes its Trip. */
    private val onTabChanged: (PanelTab) -> Unit,
    /** The Trips tab opened a Trip (`docs/SPEC.md` FR-13.6). */
    private val onOpenTrip: (tripId: String) -> Unit,
    /** The Trips tab has no Trip left to open. */
    private val onCloseTrip: () -> Unit,
    /** Add to trip's New trip… made one of the toolbar's target (`docs/SPEC.md` FR-13). */
    private val onTripCreated: (Trip) -> Unit,
    /** A Trip renamed, deleted or added to: the rows' Trip badges are out of date. */
    private val onTripsChanged: () -> Unit,
    /** A track was taken out of the open Trip on the Trips tab. */
    private val onRemovedFromTrip: (trackId: String) -> Unit,
    /** A copy of a Trip someone sent has arrived in the account (`TripsTab`). */
    private val onTripCopyArrived: () -> Unit,
    /** The Trips tab read its inbox: how many copies wait to be answered. */
    private val onTripsWaiting: (waiting: Int) -> Unit,
    /** The sheet came to rest at another height, or its peek changed. */
    private val onSheetChanged: () -> Unit,
    /** The Sync tab, `MapFragment`'s to build: it draws on the map and reads the phone. */
    val syncTab: SyncTab,
) {
    private val context = sheet.context
    private val res = context.resources

    private val behavior = BottomSheetBehavior.from(sheet)
    private val handle: View = sheet.findViewById(R.id.panel_handle)
    private val summary: TextView = sheet.findViewById(R.id.panel_summary)
    private val titleHead: View = sheet.findViewById(R.id.panel_title_head)
    private val title: TextView = sheet.findViewById(R.id.panel_title)
    private val tripsContent: View = sheet.findViewById(R.id.panel_trips_content)
    private val syncContent: View = sheet.findViewById(R.id.panel_sync_content)
    private val tracksContent: View = sheet.findViewById(R.id.panel_tracks_content)
    private val head: View = sheet.findViewById(R.id.panel_head)
    private val subtext: TextView = sheet.findViewById(R.id.panel_subtext)
    private val datesChip: View = sheet.findViewById(R.id.panel_dates)
    private val datesLabel: TextView = sheet.findViewById(R.id.panel_dates_label)
    private val datesDot: View = sheet.findViewById(R.id.panel_dates_dot)

    /** Dates' chip was tapped: its dialog is the map's (`map/DatesDialog`). */
    var onDatesTap: () -> Unit = {}

    /** The map is too far out to list anything (`docs/SPEC.md` FR-5.11). */
    private var zoomedOut = false
    /** Dates is set ([setDates]), so an empty list may be its doing. */
    private var datesSet = false
    /** TYPE, DISTANCE and Reset. */
    private val filters = TrackFilters(sheet, state, onChanged = ::changed)
    private val selectionClose: View = selectionBar.findViewById(R.id.selection_close)

    private val card: View = sheet.findViewById(R.id.track_card)
    private val cardIcon: ImageView = sheet.findViewById(R.id.card_type_icon)
    private val cardTitle: TextView = sheet.findViewById(R.id.card_title)
    private val cardMeta: TextView = sheet.findViewById(R.id.card_meta)
    private val cardDistance: TextView = sheet.findViewById(R.id.card_distance)
    private val cardMoving: TextView = sheet.findViewById(R.id.card_moving)
    private val cardPaceLabel: TextView = sheet.findViewById(R.id.card_pace_label)
    private val cardPace: TextView = sheet.findViewById(R.id.card_pace)
    private val cardBands: View = sheet.findViewById(R.id.card_bands)
    private val cardStats: View = sheet.findViewById(R.id.card_stats)
    private val cardPrivate: View = sheet.findViewById(R.id.card_private)
    private val cardVisibility: MaterialButton = sheet.findViewById(R.id.card_visibility)

    /** The actions over the toolbar's target, twice: the selection bar's icons, and the selected
     *  track's card's — the same rules and the same enabled states, whichever shows. */
    private class Actions(val visibility: View, val edit: View, val addToTrip: View, val delete: View, val focus: View)
    private val checkAll: MaterialCheckBox = selectionBar.findViewById(R.id.panel_check_all)
    private val selectMenu: ImageButton = selectionBar.findViewById(R.id.panel_select_menu)
    private val visibility: ImageButton = selectionBar.findViewById(R.id.panel_visibility)
    private val edit: ImageButton = selectionBar.findViewById(R.id.panel_edit)
    private val addToTrip: ImageButton = selectionBar.findViewById(R.id.panel_add_to_trip)
    private val delete: ImageButton = selectionBar.findViewById(R.id.panel_delete)
    private val focus: ImageButton = selectionBar.findViewById(R.id.panel_focus)
    private val list: RecyclerView = sheet.findViewById(R.id.panel_list)

    /** Over the rows while a reload runs past [PROGRESS_DELAY_MS]: the list keeps its rows until
     *  the new ones land, and a "Loading…" line below them goes unseen. */
    private val progress: View = sheet.findViewById(R.id.panel_progress)
    private val showProgress = Runnable { if (loading && !zoomedOut) progress.visibility = View.VISIBLE }
    private val footer: TextView = sheet.findViewById(R.id.panel_footer)

    private val toolbarActions = Actions(visibility, edit, addToTrip, delete, focus)
    private val cardActions = Actions(
        cardVisibility,
        sheet.findViewById(R.id.card_edit),
        sheet.findViewById(R.id.card_add_to_trip),
        sheet.findViewById(R.id.card_delete),
        sheet.findViewById(R.id.card_focus),
    )

    /** Whether the map draws the selected track's pace bands — its card shows their legend
     *  only then. */
    private var bandsShown = false

    /** The legend's steps as last drawn ([setBands]). */
    private var bandColors: List<String>? = null

    private val adapter = RowAdapter()
    var tab = PanelTab.TRACKS
        private set

    private val noteAdapter = NoteAdapter()

    /** The Trips tab — its rows are this panel's list, narrowed to the open Trip. */
    val tripsTab = TripsTab(
        tripsContent,
        onOpen = { id, collapse ->
            // The expanded sheet would cover the Trip's tracks.
            if (collapse) setExpanded(false)
            onOpenTrip(id)
        },
        onClose = { onCloseTrip() },
        onSelect = ::select,
        onClearFocus = ::clearFocus,
        onBadgesChanged = { onTripsChanged() },
        onTrackRemoved = { id -> onRemovedFromTrip(id) },
        onCopyArrived = { onTripCopyArrived() },
        onInboxRead = { onTripsWaiting(it) },
    )

    private var loading = false
    private var error: String? = null

    /** Whether the sheet is open — half the map or more — or heading there. */
    var expanded = false
        private set

    /** Where the sheet is or is heading: collapsed, half or expanded, never a moving state. */
    private var resting = BottomSheetBehavior.STATE_COLLAPSED

    /** Forced down to its head from outside without forgetting [expanded] — an edit window
     *  over the map; the sheet comes back as it was. */
    private var held = false

    /** Add to trip's menu while it's open, and the target it was opened over — a different
     *  target closes it, as on the web. */
    private val tripMenu = AddToTripMenu(context, onTripCreated, onTripsChanged)

    init {
        list.layoutManager = LinearLayoutManager(context)
        // The note — loading, nothing matching, the read failing — is the list's last item,
        // after whatever rows there are, as the web's is.
        list.adapter = ConcatAdapter(adapter, noteAdapter)
        list.itemAnimator = null
        clearFocusOnEmptyTap()

        handle.setOnClickListener { setExpanded(!expanded) }
        LargeText.stack(sheet.findViewById(R.id.card_stats))
        // The collapsed height is the head's bottom edge, whatever the font scale and the totals
        // or title in it make of it — set after the layout pass rather than inside it.
        head.addOnLayoutChangeListener { _, _, _, _, bottom, _, _, _, oldBottom ->
            if (bottom != oldBottom) head.post {
                if (behavior.peekHeight != head.bottom) {
                    behavior.peekHeight = head.bottom
                    // The open sheet's height depends on the head's.
                    (sheet.parent as? View)?.let { setExpandedOffset(expandedOffsetWanted, it.height) }
                    onSheetChanged()
                }
            }
        }
        behavior.isHideable = false
        behavior.addBottomSheetCallback(object : BottomSheetBehavior.BottomSheetCallback() {
            override fun onStateChanged(bottomSheet: View, newState: Int) {
                if (newState !in RESTING_STATES) return
                resting = newState
                // Dragged by hand: that's the sheet's height now. Held down, the drag is off and
                // the wish to come back open stays.
                if (!held) expanded = newState != BottomSheetBehavior.STATE_COLLAPSED
                render()
                onSheetChanged()
            }

            override fun onSlide(bottomSheet: View, slideOffset: Float) = Unit
        })

        datesChip.setOnClickListener { onDatesTap() }

        // Only ever shown while something is checked: partly checked, it checks every listed
        // row; all checked, it unchecks them all, which ends selecting.
        checkAll.setOnClickListener {
            val listed = state.listed
            if (listed.isNotEmpty() && listed.all { it.id in state.checked }) state.clearChecked() else state.checkAll()
            changed()
        }
        selectMenu.setOnClickListener { showSelectMenu() }
        TooltipCompat.setTooltipText(selectMenu, res.getString(R.string.panel_select_menu))
        for (actions in listOf(toolbarActions, cardActions)) {
            actions.visibility.setOnClickListener {
                state.toggleTargetVisibility()
                changed()
            }
            actions.focus.setOnClickListener {
                val hidden = state.mapHidden
                onFly(state.targets.filter { it.id !in hidden })
            }
            actions.edit.setOnClickListener { state.targets.takeIf { it.isNotEmpty() }?.let(onEdit) }
            actions.addToTrip.setOnClickListener { anchor -> if (tripMenu.target == null) showAddToTrip(anchor) else tripMenu.dismiss() }
            actions.delete.setOnClickListener { confirmDelete() }
        }
        selectionClose.setOnClickListener { endSelecting() }
        sheet.findViewById<View>(R.id.card_close).setOnClickListener { clearFocus() }
        render()
    }

    private fun showTab(next: PanelTab) {
        if (tab == next) return
        tab = next
        dismissPopups()
        if (next == PanelTab.TRIPS) tripsTab.start() else tripsTab.stop()
        if (next == PanelTab.SYNC) syncTab.start() else syncTab.stop()
        render()
        onTabChanged(next)
    }

    /** Onto the Trips tab, the sheet halfway up so its Trips show — the bottom bar's
     *  Trips, or a Trip Create trip just made, which `MapFragment` opens straight away. */
    fun showTrips() {
        showTab(PanelTab.TRIPS)
        setExpanded(true)
    }

    /** Onto the Sync tab, the sheet halfway up so its list shows over the lines it draws — the
     *  bottom bar's Sync. */
    fun showSync() {
        showTab(PanelTab.SYNC)
        setExpanded(true)
    }

    /** The Tracks tab, collapsed — the bottom bar's Tracks, or a View on map. */
    fun showTracks() {
        showTab(PanelTab.TRACKS)
        setExpanded(false)
    }

    /** A new list is on its way: for a new area, Dates or Trip, or the same one again. */
    fun setLoading() {
        loading = true
        error = null
        zoomedOut = false
        // Only once it has taken long enough to notice, so a quick pan doesn't flicker.
        progress.removeCallbacks(showProgress)
        progress.postDelayed(showProgress, PROGRESS_DELAY_MS)
        render()
    }

    fun setTracks(tracks: List<Track>) {
        loading = false
        error = null
        zoomedOut = false
        state.setTracks(tracks)
        changed()
    }

    /** Too far out to list anything: the list empties and says to zoom in. */
    fun setZoomedOut() {
        setTracks(emptyList())
        zoomedOut = true
        render()
    }

    /** Dates' chip: [text] what's set, marked while anything is. */
    fun setDates(text: String, set: Boolean) {
        datesLabel.text = text
        datesDot.visibility = if (set) View.VISIBLE else View.GONE
        datesSet = set
        datesChip.contentDescription = "${res.getString(R.string.dates_filter)}, $text"
    }

    fun setError(message: String) {
        loading = false
        error = message
        render()
    }

    /** Selects [id] and scrolls its row to the middle of the list — without expanding a
     *  collapsed sheet (`docs/SPEC.md` §20). */
    fun focusFromMap(id: String) {
        select(id)
        if (tab == PanelTab.TRIPS) tripsTab.scrollToRow(id) else scrollToRow(id)
    }

    /** A track tapped on the map: checked or unchecked while selecting, as its row's tap is,
     *  else selected ([focusFromMap]). */
    fun trackTapped(id: String) {
        if (!state.selecting || tab != PanelTab.TRACKS) return focusFromMap(id)
        checkRow(id)
        scrollToRow(id)
    }

    /** The selection bar's ×, or Back: everything unchecked, which ends selecting. */
    fun endSelecting() {
        if (!state.selecting) return
        state.clearChecked()
        changed()
    }

    /** A tap on empty map, or on the list's empty space: the selection goes, the group stays. */
    fun clearFocus() {
        if (state.focused == null) return
        state.clearFocus()
        changed()
    }

    /** Halfway up, or down to its head. */
    fun setExpanded(next: Boolean) {
        expanded = next
        if (!held) moveTo(if (next) BottomSheetBehavior.STATE_HALF_EXPANDED else BottomSheetBehavior.STATE_COLLAPSED)
        render()
    }

    /** See [held]. The sheet can't be dragged while held. */
    fun hold(down: Boolean) {
        if (held == down) return
        held = down
        behavior.isDraggable = !down
        moveTo(if (expanded && !down) BottomSheetBehavior.STATE_HALF_EXPANDED else BottomSheetBehavior.STATE_COLLAPSED)
        render()
    }

    private fun moveTo(state: Int) {
        resting = state
        behavior.state = state
    }

    /** Where the sheet's top edge is, or is heading, in a parent [parentHeight] tall — what the
     *  camera frames above. */
    fun restingTop(parentHeight: Int): Int = when (resting) {
        BottomSheetBehavior.STATE_EXPANDED -> behavior.expandedOffset
        BottomSheetBehavior.STATE_HALF_EXPANDED -> (parentHeight * (1 - behavior.halfExpandedRatio)).toInt()
        else -> parentHeight - behavior.peekHeight
    }

    /** The offset last asked for, before [setExpandedOffset] clamps it. */
    private var expandedOffsetWanted = 0

    /** How far down the expanded sheet's top stops — under the map's top row, where there's
     *  room — in a parent [parentHeight] tall. The sheet is that much shorter than its parent, so expanded, its
     *  bottom — the list's last rows — is still on screen. */
    fun setExpandedOffset(offset: Int, parentHeight: Int) {
        // Never so far down that the open sheet is shorter than its own head — a landscape
        // phone, whose top row, the rail's two buttons stacked, takes much of its height. The
        // head's own height, not the one it was laid out at: a sheet already too short squeezes
        // its head, which would then never ask for more.
        expandedOffsetWanted = offset
        val clamped = offset.coerceAtMost((parentHeight - naturalHeadHeight()).coerceAtLeast(0))
        if (behavior.expandedOffset != clamped) behavior.expandedOffset = clamped
        val params = sheet.layoutParams
        val height = (parentHeight - clamped).coerceAtLeast(0)
        if (params.height != height) {
            params.height = height
            sheet.layoutParams = params
        }
    }

    /** The head's height at the sheet's width with nothing limiting it. */
    private fun naturalHeadHeight(): Int {
        val width = sheet.width.takeIf { it > 0 } ?: return head.height
        head.measure(
            View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED),
        )
        return head.measuredHeight
    }

    fun dismissPopups() {
        filters.dismiss()
        tripMenu.dismiss()
    }

    /** Whether the rows are being checked — the selection bar over the map then. */
    val selecting: Boolean get() = state.selecting

    /** Whether the selected track's card is at the sheet's head, in the totals' place. */
    val showsCard: Boolean get() = tab == PanelTab.TRACKS && state.focused != null && !state.selecting

    /** The map draws the selected track's pace bands in [colors], slowest first, or stopped
     *  (null): the card's legend follows. */
    fun setBands(colors: List<String>?) {
        if (colors != null && colors != bandColors) {
            bandColors = colors
            sheet.findViewById<LinearLayout>(R.id.card_band_steps).apply {
                removeAllViews()
                val gap = res.getDimensionPixelSize(R.dimen.hmt_space_2)
                colors.forEachIndexed { i, color ->
                    addView(View(context).apply {
                        setBackgroundResource(R.drawable.bg_pace_band)
                        backgroundTintList = ColorStateList.valueOf(Color.parseColor(color))
                    }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f).apply {
                        if (i > 0) marginStart = gap
                    })
                }
            }
        }
        if (bandsShown == (colors != null)) return
        bandsShown = colors != null
        renderCard()
    }

    /** The collapsed sheet's height: its head. */
    val peekHeight: Int
        get() = behavior.peekHeight

    private fun select(id: String) {
        state.focus(id)
        val hidden = state.mapHidden
        onFly(state.tracks.filter { it.id == id && it.id !in hidden })
        changed()
    }

    private fun changed() {
        onMapChanged()
        render()
    }

    private fun render() {
        if (!loading || zoomedOut) {
            progress.removeCallbacks(showProgress)
            progress.visibility = View.INVISIBLE
        }
        val listed = state.listed
        // The Tracks tab's own totals: an open Trip's rows are the list meanwhile, and
        // aren't what the area's heading counts, as on the web.
        if (tab == PanelTab.TRACKS) summary.text = summaryOf(listed)
        renderTabs()
        subtext.visibility = if (tab == PanelTab.TRACKS) View.GONE else View.VISIBLE
        subtext.setText(if (tab == PanelTab.SYNC) R.string.sync_subtext else R.string.trip_subtext)
        // Held down under an edit, the sheet is collapsed whatever it was.
        val open = expanded && !held
        handle.contentDescription = res.getString(if (open) R.string.panel_collapse else R.string.panel_expand)

        renderCard()
        filters.render()
        renderToolbar(listed)

        val rows = listed.map { TrackRowItem(it, checked = it.id in state.checked, focused = it.id == state.focused, hidden = it.id in state.hidden, selecting = state.selecting) }
        adapter.submitList(rows)
        if (tab == PanelTab.TRIPS) tripsTab.setRows(rows, loading, error)
        noteAdapter.note = when {
            zoomedOut && tab == PanelTab.TRACKS -> Note(res.getString(R.string.area_zoom_in), failed = false)
            loading && listed.isEmpty() -> Note(res.getString(R.string.panel_loading), failed = false)
            loading -> null
            error != null -> Note(error!!, failed = true)
            listed.isEmpty() -> Note(
                res.getString(if (PanelRules.emptyListFiltered(state.hasActiveFilters, datesSet)) R.string.panel_none_match else R.string.panel_none_here),
                failed = false,
            )
            else -> null
        }

        val targets = state.targets
        footer.text = res.getString(
            R.string.panel_footer,
            targets.size,
            PanelFormat.totalDistance(res, targets.sumOf { it.distanceMeters ?: 0.0 }),
        )
        if (tripMenu.target.let { it != null && it != targets.map { t -> t.id } }) tripMenu.dismiss()
    }

    /** "6 tracks · 74.8 km · 9h 6m", what's listed in the area. */
    private fun summaryOf(listed: List<Track>): String = listOf(
        res.getQuantityString(R.plurals.trip_track_count, listed.size, listed.size),
        PanelFormat.totalDistance(res, listed.sumOf { it.distanceMeters ?: 0.0 }),
        PanelFormat.duration(res, listed.sumOf { it.movingSeconds ?: 0L }),
    ).joinToString(" · ")

    /** The tab's head, the Tracks tab's totals or Trips' and Sync's titles, and its content
     *  in the sheet. */
    private fun renderTabs() {
        titleHead.visibility = if (tab == PanelTab.TRACKS) View.GONE else View.VISIBLE
        title.setText(if (tab == PanelTab.SYNC) R.string.sync_title else R.string.panel_tab_trips)
        tracksContent.visibility = if (tab == PanelTab.TRACKS) View.VISIBLE else View.GONE
        tripsContent.visibility = if (tab == PanelTab.TRIPS) View.VISIBLE else View.GONE
        syncContent.visibility = if (tab == PanelTab.SYNC) View.VISIBLE else View.GONE
    }

    private fun renderToolbar(listed: List<Track>) {
        val all = ToolbarRules.checkAll(listed.size, listed.count { it.id in state.checked })
        checkAll.isEnabled = listed.isNotEmpty()
        checkAll.checkedState = when (all) {
            ToolbarRules.CheckAll.ALL -> MaterialCheckBox.STATE_CHECKED
            ToolbarRules.CheckAll.SOME -> MaterialCheckBox.STATE_INDETERMINATE
            ToolbarRules.CheckAll.NONE -> MaterialCheckBox.STATE_UNCHECKED
        }
        checkAll.contentDescription = res.getString(if (all == ToolbarRules.CheckAll.ALL) R.string.panel_uncheck_all else R.string.panel_check_all)
        selectMenu.isEnabled = listed.isNotEmpty()

        // The toolbar names its target, so which of the group and the selected row it acts on
        // is never a guess: "3 checked tracks", or the selected row's own label.
        val targets = state.targets
        val targetName = when {
            targets.isEmpty() -> null
            state.checked.isNotEmpty() -> res.getQuantityString(R.plurals.panel_checked_count, targets.size, targets.size)
            else -> res.getString(R.string.panel_target_one, PanelFormat.rowLabel(res, targets.first()))
        }
        val noTarget = res.getString(R.string.panel_no_target)
        val anyHidden = targets.any { it.id in state.hidden }
        visibility.setImageResource(if (anyHidden) R.drawable.ic_eye_off else R.drawable.ic_eye)
        cardVisibility.setIconResource(if (anyHidden) R.drawable.ic_eye_off else R.drawable.ic_eye)
        cardVisibility.setText(if (anyHidden) R.string.card_show else R.string.card_hide)
        for (actions in listOf(toolbarActions, cardActions)) describeActions(actions, targets, targetName, noTarget, anyHidden)
    }

    /** Each action says what it would do, or why it can't (as the web's do): disabled actions
     *  stay visible. */
    private fun describeActions(actions: Actions, targets: List<Track>, targetName: String?, noTarget: String, anyHidden: Boolean) {
        val use = ToolbarRules.actions(targets.size, targets.any { it.pending }, Session.isDemo)
        fun text(of: ToolbarRules.Use, demo: Int, ready: () -> String) = when (of) {
            ToolbarRules.Use.DEMO -> res.getString(demo)
            ToolbarRules.Use.NO_TARGET -> noTarget
            ToolbarRules.Use.READY, ToolbarRules.Use.PENDING -> ready()
        }
        fun ToolbarRules.Use.enabled() = this == ToolbarRules.Use.READY
        describe(
            actions.visibility,
            text(use.visibility, 0) { res.getString(if (anyHidden) R.string.panel_show_target else R.string.panel_hide_target, targetName) },
            use.visibility.enabled(),
        )
        describe(
            actions.edit,
            text(use.edit, R.string.panel_demo_edit) {
                res.getString(if (targets.size == 1) R.string.panel_edit_one else R.string.panel_edit_many, targetName)
            },
            use.edit.enabled(),
        )
        describe(actions.addToTrip, text(use.addToTrip, R.string.trip_demo_add) { res.getString(R.string.trip_add_target, targetName) }, use.addToTrip.enabled())
        describe(actions.delete, text(use.delete, R.string.panel_demo_delete) { res.getString(R.string.panel_delete_target, targetName) }, use.delete.enabled())
        describe(actions.focus, text(use.focus, 0) { res.getString(R.string.panel_focus_target, targetName) }, use.focus.enabled())
    }

    /** The master checkbox's ▾ (the web's `.select-menu`): All, None and Invert over the listed
     *  rows — All disabled once every one is checked, None once nothing is. */
    private fun showSelectMenu() {
        val listed = state.listed
        val checkedCount = listed.count { it.id in state.checked }
        val menu = PopupMenu(context, selectMenu)
        menu.menu.add(0, SELECT_ALL, 0, R.string.panel_select_all).isEnabled = checkedCount < listed.size
        menu.menu.add(0, SELECT_NONE, 1, R.string.panel_select_none).isEnabled = state.checked.isNotEmpty()
        menu.menu.add(0, SELECT_INVERT, 2, R.string.panel_select_invert)
        menu.setOnMenuItemClickListener { item ->
            when (item.itemId) {
                SELECT_ALL -> state.checkAll()
                SELECT_NONE -> state.clearChecked()
                SELECT_INVERT -> state.invertChecked()
            }
            changed()
            true
        }
        menu.show()
    }

    /** The toolbar's name for its target, for the delete confirmation: "3 checked tracks
     *  (16 km)", or the selected row's own title and distance. */
    private fun targetSummary(targets: List<Track>): String {
        val name = if (state.checked.isNotEmpty()) {
            res.getQuantityString(R.plurals.panel_checked_count, targets.size, targets.size)
        } else {
            res.getString(R.string.panel_target_one, PanelFormat.rowLabel(res, targets.first()))
        }
        return res.getString(R.string.panel_group_summary, name, PanelFormat.totalDistance(res, targets.sumOf { it.distanceMeters ?: 0.0 }))
    }

    /** Opens Add to trip's menu ([AddToTripMenu]) over the toolbar's target. */
    private fun showAddToTrip(anchor: View) {
        val targets = state.targets
        if (targets.isEmpty() || Session.isDemo) return
        tripMenu.show(anchor, targets.map { it.id }, targetSummary(targets))
    }

    /**
     * Delete, over the toolbar's target, after a confirmation that says what goes with it
     * (`docs/SPEC.md` FR-5.6). The dialog stays up while the deletes run — one at a time, as
     * the web's are, rather than a burst racing each other's coverage re-render — and keeps a
     * failure on screen rather than closing over it.
     */
    private fun confirmDelete() {
        val targets = state.targets
        if (targets.isEmpty()) return
        val one = targets.size == 1
        val summary = targetSummary(targets)
        val dialog = MaterialAlertDialogBuilder(context, R.style.ThemeOverlay_HoldMyTrack_Dialog_Destructive)
            .setTitle(if (one) R.string.panel_delete_one_title else R.string.panel_delete_title)
            .setMessage(res.getString(if (one) R.string.panel_delete_one_body else R.string.panel_delete_many_body, summary))
            .setPositiveButton(R.string.panel_delete_confirm, null)
            .setNegativeButton(android.R.string.cancel, null)
            .create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener { deleteNext(dialog, targets.map { it.id }, 0) }
        }
        dialog.show()
    }

    private fun deleteNext(dialog: AlertDialog, ids: List<String>, index: Int) {
        val confirm = dialog.getButton(AlertDialog.BUTTON_POSITIVE)
        val cancel = dialog.getButton(AlertDialog.BUTTON_NEGATIVE)
        if (index == ids.size) {
            dialog.dismiss()
            onDeleted(ids)
            return
        }
        dialog.setCancelable(false)
        confirm.isEnabled = false
        cancel.isEnabled = false
        confirm.setText(R.string.panel_deleting)
        HoldMyTrackApi.deleteTrack(ids[index]) { result ->
            result.onSuccess { deleteNext(dialog, ids, index + 1) }
                .onFailure { failure ->
                    // What did go is gone: report those, and say why the rest didn't.
                    if (index > 0) onDeleted(ids.take(index))
                    dialog.setCancelable(true)
                    confirm.isEnabled = true
                    cancel.isEnabled = true
                    confirm.setText(R.string.panel_delete_confirm)
                    dialog.setMessage(res.getString(R.string.panel_delete_failed, FailureText.of(failure, res.getString(R.string.something_went_wrong), res.getString(R.string.network_error))))
                    confirm.setOnClickListener { deleteNext(dialog, ids, index) }
                }
        }
    }

    /** The selected track's card (`include_track_card`), at the head while [showsCard]. */
    private fun renderCard() {
        val track = state.focused?.let { id -> state.tracks.firstOrNull { it.id == id } }
        val shown = showsCard && track != null
        card.visibility = if (shown) View.VISIBLE else View.GONE
        if (!shown || track == null) return
        val kind = TrackTypes.kind(track.trackType)
        cardIcon.setImageResource(typeIcon(track.trackType))
        cardTitle.text = PanelFormat.rowLabel(res, track)
        // The start moves under the title once a name has taken it, as on a row.
        val named = track.name?.trim()?.isNotEmpty() == true
        cardMeta.text = listOfNotNull(
            PanelFormat.startedAt(res, track.startedAt, track.timezone).takeIf { named },
            TrackTypes.label(track.trackType),
        ).joinToString(" · ")
        // A private track has no stats worth showing (FR-5.1): what it is stands in for them.
        cardStats.visibility = if (track.isPrivate) View.GONE else View.VISIBLE
        cardPrivate.visibility = if (track.isPrivate) View.VISIBLE else View.GONE
        cardDistance.text = PanelFormat.distance(res, track.distanceMeters)
        cardMoving.text = PanelFormat.duration(res, track.movingSeconds)
        cardPaceLabel.setText(if (kind.showsPace) R.string.card_pace else R.string.card_speed)
        cardPace.text = PanelFormat.paceOrSpeed(res, kind, track.distanceMeters, track.movingSeconds)
        cardBands.visibility = if (bandsShown) View.VISIBLE else View.GONE
    }

    private fun describe(button: View, text: String, enabled: Boolean) {
        button.isEnabled = enabled
        button.contentDescription = text
        TooltipCompat.setTooltipText(button, text)
    }

    /** Centres [id]'s row in the list — the list alone, never the sheet around it, so a
     *  collapsed sheet stays exactly as it was. */
    private fun scrollToRow(id: String) {
        val position = adapter.currentList.indexOfFirst { it.track.id == id }
        if (position < 0) return
        list.post {
            val manager = list.layoutManager as LinearLayoutManager
            val rowHeight = list.getChildAt(0)?.height ?: 0
            manager.scrollToPositionWithOffset(position, (list.height - rowHeight) / 2)
        }
    }

    @SuppressLint("ClickableViewAccessibility") // A tap on no row at all; each row is its own target.
    private fun clearFocusOnEmptyTap() {
        val detector = GestureDetector(
            context,
            object : GestureDetector.SimpleOnGestureListener() {
                override fun onSingleTapUp(e: MotionEvent): Boolean {
                    if (list.findChildViewUnder(e.x, e.y) == null) clearFocus()
                    return false
                }
            },
        )
        list.setOnTouchListener { _, event ->
            detector.onTouchEvent(event)
            false
        }
    }

    private data class Note(val text: String, val failed: Boolean)

    /** The list's note, as its one last item — or no item at all. A tap on it clears the
     *  selection, like a tap on the list's empty space. */
    private inner class NoteAdapter : RecyclerView.Adapter<RecyclerView.ViewHolder>() {
        var note: Note? = null
            set(value) {
                if (field == value) return
                val had = field != null
                field = value
                when {
                    had && value == null -> notifyItemRemoved(0)
                    !had && value != null -> notifyItemInserted(0)
                    value != null -> notifyItemChanged(0)
                }
            }

        override fun getItemCount() = if (note == null) 0 else 1

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RecyclerView.ViewHolder {
            val view = LayoutInflater.from(parent.context).inflate(R.layout.item_panel_note, parent, false)
            view.setOnClickListener { clearFocus() }
            return object : RecyclerView.ViewHolder(view) {}
        }

        override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {
            val current = note ?: return
            (holder.itemView as TextView).apply {
                text = current.text
                setTextColor(context.getColor(if (current.failed) R.color.hmt_danger else R.color.panel_ink_50))
            }
        }
    }

    private inner class RowAdapter : ListAdapter<TrackRowItem, TrackRowHolder>(
        object : DiffUtil.ItemCallback<TrackRowItem>() {
            override fun areItemsTheSame(old: TrackRowItem, new: TrackRowItem) = old.track.id == new.track.id
            override fun areContentsTheSame(old: TrackRowItem, new: TrackRowItem) = old == new
        },
    ) {
        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) =
            TrackRowHolder(LayoutInflater.from(parent.context).inflate(R.layout.item_track_row, parent, false))

        override fun onBindViewHolder(holder: TrackRowHolder, position: Int) = holder.bind(
            getItem(position),
            openTripId = null,
            // The tile, or a long press, checks; while selecting, so does the row's tap.
            onCheck = ::checkRow,
            onSelect = if (getItem(position).selecting) ::checkRow else ::selectRow,
            onOpenTrip = ::openTrip,
        )
    }

    /** Checks [id] — starting selecting if nothing was — and flies to it, or unchecks it and
     *  leaves the camera be. The sheet stays where it is, so the next row is a tap away. */
    private fun checkRow(id: String) {
        if (state.toggleChecked(id)) {
            val hidden = state.mapHidden
            onFly(state.tracks.filter { it.id == id && it.id !in hidden })
        }
        changed()
    }

    /** A row's tap: selected, and the sheet down to its card, so the track shows. */
    private fun selectRow(id: String) {
        select(id)
        setExpanded(false)
    }

    /** A row's Trip badge: that Trip, on the Trips tab, the sheet down so its tracks show. */
    private fun openTrip(id: String) {
        setExpanded(false)
        onOpenTrip(id)
    }

    internal companion object {
        /** How long a list load runs before the progress bar shows. */
        const val PROGRESS_DELAY_MS = 300L

        /** About twelve rows, then a dropdown's list scrolls ([TrackFilters], [AddToTripMenu]). */
        const val TYPE_LIST_MAX_DP = 192

        val RESTING_STATES = setOf(
            BottomSheetBehavior.STATE_COLLAPSED,
            BottomSheetBehavior.STATE_HALF_EXPANDED,
            BottomSheetBehavior.STATE_EXPANDED,
        )
        const val SELECT_ALL = 1
        const val SELECT_NONE = 2
        const val SELECT_INVERT = 3
    }
}
