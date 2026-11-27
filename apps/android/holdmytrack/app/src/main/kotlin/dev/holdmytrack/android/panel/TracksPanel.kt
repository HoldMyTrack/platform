package dev.holdmytrack.android.panel

import android.annotation.SuppressLint
import android.view.GestureDetector
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.ImageButton
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
import com.google.android.material.checkbox.MaterialCheckBox
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import dev.holdmytrack.android.R
import dev.holdmytrack.android.net.FailureText
import dev.holdmytrack.android.net.Track
import dev.holdmytrack.android.net.HoldMyTrackApi
import dev.holdmytrack.android.net.Session
import dev.holdmytrack.android.net.Trip

/** The panel's tabs: the web's `PanelTab`, and the bottom bar's Sync. */
enum class PanelTab { TRACKS, TRIPS, LIBRARY, SYNC }

/**
 * The map's Tracks sheet (`apps/web/src/ui/TracksPanel.tsx`, redrawn for a phone): a
 * bottom sheet dragged between collapsed — its head alone — half the map and nearly all of it
 * (`BottomSheetBehavior`), a tap on its handle opening it halfway or closing it. On the
 * Tracks tab its head is the listed tracks' totals ([render]), the visible area's under
 * Dates (`map/AreaController`), or the toolbar while it has a target, and under it the master
 * checkbox with the Type, Dates and DISTANCE filters, the rows and the target's summary. The Trips tab — the
 * bottom bar's Trips — has the account's Trips with one open on the map ([TripsTab]); the
 * Library tab — the bottom bar's Library — every track the account keeps, a page at a time
 * ([LibraryTab]); the Sync tab — Library › Sync — what's on this phone waiting to be added
 * ([SyncTab]). Only the Tracks tab has a head: the bar names the others.
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
    /** The Library tab, `MapFragment`'s to build: its Download needs the fragment. */
    val libraryTab: LibraryTab,
    /** The toolbar's Download, Library's too: its save screen needs the fragment. */
    private val download: TrackDownload,
) {
    private val context = sheet.context
    private val res = context.resources

    private val behavior = BottomSheetBehavior.from(sheet)
    private val handle: View = sheet.findViewById(R.id.panel_handle)
    private val summary: TextView = sheet.findViewById(R.id.panel_summary)
    private val tripsContent: View = sheet.findViewById(R.id.panel_trips_content)
    private val syncContent: View = sheet.findViewById(R.id.panel_sync_content)
    private val libraryContent: View = sheet.findViewById(R.id.panel_library_content)
    private val tracksContent: View = sheet.findViewById(R.id.panel_tracks_content)
    private val head: View = sheet.findViewById(R.id.panel_head)
    private val datesChip: View = sheet.findViewById(R.id.panel_dates)
    private val datesLabel: TextView = sheet.findViewById(R.id.panel_dates_label)
    private val datesDot: View = sheet.findViewById(R.id.panel_dates_dot)

    /** Dates' chip was tapped: its sheet is the map's (`map/DatesSheet`). */
    var onDatesTap: () -> Unit = {}

    /** The map is too far out to list anything (`docs/SPEC.md` FR-5.11). */
    private var zoomedOut = false
    /** Dates is set ([setDates]), so an empty list may be its doing. */
    private var datesSet = false
    /** TYPE, DISTANCE and Reset. */
    private val filters = TrackFilters(sheet, state, onChanged = ::changed)

    /** The toolbar (`include_track_actions`): the actions over its target, Download and Delete in
     *  its ⋯ menu ([SelectionMoreMenu]). */
    private val actions: View = sheet.findViewById(R.id.track_actions)
    private val checkAll: MaterialCheckBox = sheet.findViewById(R.id.panel_check_all)
    private val selectMenu: ImageButton = sheet.findViewById(R.id.panel_select_menu)
    private val visibility: ImageButton = sheet.findViewById(R.id.panel_visibility)
    private val edit: ImageButton = sheet.findViewById(R.id.panel_edit)
    private val addToTrip: ImageButton = sheet.findViewById(R.id.panel_add_to_trip)
    private val info: ImageButton = sheet.findViewById(R.id.panel_info)
    private val more = SelectionMoreMenu(sheet.findViewById(R.id.panel_more), download, onDelete = { confirmDelete() })
    private val focus: ImageButton = sheet.findViewById(R.id.panel_focus)
    private val list: RecyclerView = sheet.findViewById(R.id.panel_list)

    /** Over the rows while a reload runs past [PROGRESS_DELAY_MS]: the list keeps its rows until
     *  the new ones land, and a "Loading…" line below them goes unseen. */
    private val progress: View = sheet.findViewById(R.id.panel_progress)
    private val showProgress = Runnable { if (loading && !zoomedOut) progress.visibility = View.VISIBLE }
    private val footer: TextView = sheet.findViewById(R.id.panel_footer)

    /** The pace bands' colors while the map draws them for the focused track, else null: Info
     *  shows their legend then ([setBands]). */
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

    /** Add to trip while it's open, and the target it was opened over: a different target
     *  closes it. */
    private val tripSheet = AddToTripSheet(context, onTripCreated, onTripsChanged)

    init {
        list.layoutManager = LinearLayoutManager(context)
        // The note — loading, nothing matching, the read failing — is the list's last item,
        // after whatever rows there are, as the web's is.
        list.adapter = ConcatAdapter(adapter, noteAdapter)
        list.itemAnimator = null
        clearFocusOnEmptyTap()

        handle.setOnClickListener { setExpanded(!expanded) }
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
        // A swipe on a list scrolls it at any height; the head and its handle move the sheet.
        // Material's default lets the list's swipe grow the sheet first, so short of full screen
        // its rows never scrolled.
        behavior.isDraggableOnNestedScroll = false
        // Before each frame, after BottomSheetBehavior has moved the sheet to its state's top: a
        // rotation or a new window size lays it out at the old top first, so a padding computed on
        // layout left the content's bottom off screen. A frame whose padding changes is skipped
        // and drawn again with it, so the old one never shows. A moving sheet keeps its padding
        // until it comes to rest ([SheetFit]).
        sheet.viewTreeObserver.addOnPreDrawListener { !fitContent() }
        behavior.addBottomSheetCallback(object : BottomSheetBehavior.BottomSheetCallback() {
            override fun onStateChanged(bottomSheet: View, newState: Int) {
                if (newState !in RESTING_STATES) return
                resting = newState
                fitContent()
                // Dragged by hand: that's the sheet's height now. Held down, the drag is off and
                // the wish to come back open stays.
                if (!held) expanded = newState != BottomSheetBehavior.STATE_COLLAPSED
                render()
                onSheetChanged()
            }

            override fun onSlide(bottomSheet: View, slideOffset: Float) = Unit
        })

        datesChip.setOnClickListener { onDatesTap() }

        // ToolbarRules.masterTap: unchecking them all ends selecting.
        checkAll.setOnClickListener {
            val listed = state.listed
            when (ToolbarRules.masterTap(listed.size, listed.count { it.id in state.checked })) {
                ToolbarRules.MasterTap.UNCHECK_ALL -> state.clearChecked()
                ToolbarRules.MasterTap.CHECK_ALL -> state.checkAll()
            }
            changed()
        }
        selectMenu.setOnClickListener { showSelectMenu() }
        TooltipCompat.setTooltipText(selectMenu, res.getString(R.string.panel_select_menu))
        visibility.setOnClickListener {
            state.toggleTargetVisibility()
            changed()
        }
        focus.setOnClickListener {
            val hidden = state.mapHidden
            onFly(state.targets.filter { it.id !in hidden })
        }
        edit.setOnClickListener { state.targets.takeIf { it.isNotEmpty() }?.let(onEdit) }
        addToTrip.setOnClickListener { showAddToTrip() }
        info.setOnClickListener { showInfo() }
        render()
    }

    private fun showTab(next: PanelTab) {
        if (tab == next) return
        tab = next
        dismissPopups()
        if (next == PanelTab.TRIPS) tripsTab.start() else tripsTab.stop()
        if (next == PanelTab.SYNC) syncTab.start() else syncTab.stop()
        if (next == PanelTab.LIBRARY) libraryTab.start() else libraryTab.stop()
        render()
        onTabChanged(next)
    }

    /** Onto the Trips tab, the sheet halfway up so its Trips show — the bottom bar's
     *  Trips, or a Trip Create trip just made, which `MapFragment` opens straight away. */
    fun showTrips() {
        showTab(PanelTab.TRIPS)
        setExpanded(true)
    }

    /** Onto the Library tab, the sheet halfway up so its rows show — the bottom bar's Library. */
    fun showLibrary() {
        showTab(PanelTab.LIBRARY)
        setExpanded(true)
    }

    /** Onto the Sync tab, the sheet halfway up so its list shows over the lines it draws —
     *  Library › Sync. */
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
     *  collapsed sheet (`docs/SPEC.md` §21). */
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

    /** Back: everything unchecked, which ends selecting. */
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

    /** Ends the content at the screen's bottom wherever the sheet's top is ([SheetFit]); whether
     *  the padding changed. */
    private fun fitContent(): Boolean {
        val parentHeight = (sheet.parent as? View)?.height?.takeIf { it > 0 } ?: return false
        val halfTop = (parentHeight * (1 - behavior.halfExpandedRatio)).toInt()
        val fitFor = behavior.expandedOffset to halfTop
        val moving = behavior.state !in RESTING_STATES
        val padding = SheetFit.bottomPadding(sheet.top, fitFor.first, halfTop, sheet.paddingBottom, moving, resized = fitFor != fittedFor)
        fittedFor = fitFor
        if (sheet.paddingBottom == padding) return false
        sheet.setPadding(sheet.paddingLeft, sheet.paddingTop, sheet.paddingRight, padding)
        return true
    }

    /** The open and half tops the padding was last fitted for. */
    private var fittedFor: Pair<Int, Int>? = null

    /** The offset last asked for, before [setExpandedOffset] clamps it. */
    private var expandedOffsetWanted = 0

    /** How far down the expanded sheet's top stops — under the status bar — in a parent
     *  [parentHeight] tall. The sheet is that much shorter than its parent, so expanded, its
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
        tripSheet.dismiss()
    }

    /** Whether the rows are being checked. */
    val selecting: Boolean get() = state.selecting

    /** Whether the toolbar is at the sheet's head, in the totals' place: the Tracks tab's, while
     *  it has a target. */
    val showsActions: Boolean get() = tab == PanelTab.TRACKS && state.targets.isNotEmpty()

    /** The map draws the focused track's pace bands in [colors], slowest first, or stopped (null). */
    fun setBands(colors: List<String>?) {
        bandColors = colors
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
        // Held down under an edit, the sheet is collapsed whatever it was.
        val open = expanded && !held
        handle.contentDescription = res.getString(if (open) R.string.panel_collapse else R.string.panel_expand)

        renderActions()
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
        val distance = PanelFormat.totalDistance(res, targets.sumOf { it.distanceMeters ?: 0.0 })
        footer.text = when (PanelRules.targetSummaryKind(state.checked.size, targets.size)) {
            PanelRules.SummaryKind.FOCUSED -> res.getString(R.string.panel_footer_focused, PanelFormat.rowLabel(res, targets.first()), distance)
            PanelRules.SummaryKind.CHECKED -> res.getString(R.string.panel_footer, targets.size, distance)
        }
        if (tripSheet.target.let { it != null && it != targets.map { t -> t.id } }) tripSheet.dismiss()
    }

    /** "6 tracks · 74.8 km · 9h 6m", what's listed in the area. */
    private fun summaryOf(listed: List<Track>): String = listOf(
        res.getQuantityString(R.plurals.trip_track_count, listed.size, listed.size),
        PanelFormat.totalDistance(res, listed.sumOf { it.distanceMeters ?: 0.0 }),
        PanelFormat.duration(res, listed.sumOf { it.movingSeconds ?: 0L }),
    ).joinToString(" · ")

    /** The tab's content in the sheet. */
    private fun renderTabs() {
        tracksContent.visibility = if (tab == PanelTab.TRACKS) View.VISIBLE else View.GONE
        tripsContent.visibility = if (tab == PanelTab.TRIPS) View.VISIBLE else View.GONE
        syncContent.visibility = if (tab == PanelTab.SYNC) View.VISIBLE else View.GONE
        libraryContent.visibility = if (tab == PanelTab.LIBRARY) View.VISIBLE else View.GONE
    }

    private fun renderToolbar(listed: List<Track>) {
        // One count for the box's look and its label, so the two can't disagree.
        val checkedCount = listed.count { it.id in state.checked }
        val all = ToolbarRules.checkAll(listed.size, checkedCount)
        checkAll.isEnabled = listed.isNotEmpty()
        checkAll.checkedState = when (all) {
            ToolbarRules.CheckAll.ALL -> MaterialCheckBox.STATE_CHECKED
            ToolbarRules.CheckAll.SOME -> MaterialCheckBox.STATE_INDETERMINATE
            ToolbarRules.CheckAll.NONE -> MaterialCheckBox.STATE_UNCHECKED
        }
        val clears = ToolbarRules.masterTap(listed.size, checkedCount) == ToolbarRules.MasterTap.UNCHECK_ALL
        checkAll.contentDescription = res.getString(if (clears) R.string.panel_uncheck_all else R.string.panel_check_all)
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
        // What a tap does: show (the open eye) or hide (crossed out).
        visibility.setImageResource(if (anyHidden) R.drawable.ic_eye else R.drawable.ic_eye_off)
        describeActions(targets, targetName, noTarget, anyHidden)
    }

    /** The target [describeActions] last named its actions for. */
    private var describedTargets: List<String> = emptyList()

    /** Each action says what it would do, or why it can't (as the web's do): disabled actions
     *  stay visible. */
    private fun describeActions(targets: List<Track>, targetName: String?, noTarget: String, anyHidden: Boolean) {
        val use = ToolbarRules.actions(targets.size, targets.any { it.pending }, Session.isDemo)
        fun text(of: ToolbarRules.Use, demo: Int, ready: () -> String) = when (of) {
            ToolbarRules.Use.DEMO -> res.getString(demo)
            ToolbarRules.Use.NO_TARGET -> noTarget
            ToolbarRules.Use.READY -> ready()
            // Only Delete waits for a Pending target, so it alone names the track.
            ToolbarRules.Use.PENDING -> res.getString(R.string.panel_delete_pending, PanelFormat.rowLabel(res, targets.first { it.pending }))
        }
        fun ToolbarRules.Use.enabled() = this == ToolbarRules.Use.READY
        describe(
            visibility,
            text(use.visibility, 0) { res.getString(if (anyHidden) R.string.panel_show_target else R.string.panel_hide_target, targetName) },
            use.visibility.enabled(),
        )
        describe(
            edit,
            text(use.edit, R.string.panel_demo_edit) {
                res.getString(if (targets.size == 1) R.string.panel_edit_one else R.string.panel_edit_many, targetName)
            },
            use.edit.enabled(),
        )
        describe(addToTrip, text(use.addToTrip, R.string.trip_demo_add) { res.getString(R.string.trip_add_target, targetName) }, use.addToTrip.enabled())
        describe(info, text(use.info, 0) { res.getString(R.string.panel_info_target, targetName) }, use.info.enabled())
        val deleteText = text(use.delete, R.string.panel_demo_delete) { res.getString(R.string.panel_delete_target, targetName) }
        // A menu opened over another target, or none, would act on rows the toolbar no longer names.
        val ids = targets.map { it.id }
        if (ids != describedTargets) {
            tripSheet.dismiss()
            more.dismiss()
            describedTargets = ids
        }
        more.update(targets, targetName, noTarget, deleteText, use.delete.enabled())
        describe(focus, text(use.focus, 0) { res.getString(R.string.panel_focus_target, targetName) }, use.focus.enabled())
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

    /** Info ([TrackInfoSheet]) over the toolbar's target, with the bands' legend while they're
     *  drawn for the focused track alone. */
    private fun showInfo() {
        val targets = state.targets
        if (targets.isEmpty()) return
        infoSheet?.dismiss()
        infoSheet = TrackInfoSheet(context, targets.map { it.id }, bandColors.takeIf { PanelRules.infoShowsBands(state.checked, state.focused, it != null) }).also { it.show() }
    }

    /** The Info open, if any, which goes with the fragment's views ([dismissDialogs]). */
    private var infoSheet: TrackInfoSheet? = null

    /** The views are going: Info would leak its window, and a late reply would write into them. */
    fun dismissDialogs() {
        infoSheet?.dismiss()
        infoSheet = null
        dismissPopups()
        more.dismiss()
    }

    /** Opens Add to trip ([AddToTripSheet]) over the toolbar's target. */
    private fun showAddToTrip() {
        val targets = state.targets
        if (targets.isEmpty() || Session.isDemo) return
        tripSheet.show(targets.map { it.id }, targetSummary(targets))
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

    /** The toolbar at the head while [showsActions]. */
    private fun renderActions() {
        actions.visibility = if (showsActions) View.VISIBLE else View.GONE
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

    /** A row's tap: focused, the sheet where [SheetRules.afterRowTap] puts it, and then the
     *  camera, which frames the track above where the sheet comes to rest. */
    private fun selectRow(id: String) {
        val now = when (resting) {
            BottomSheetBehavior.STATE_EXPANDED -> SheetRules.Detent.EXPANDED
            BottomSheetBehavior.STATE_HALF_EXPANDED -> SheetRules.Detent.HALF
            else -> SheetRules.Detent.COLLAPSED
        }
        if (SheetRules.afterRowTap(now) == SheetRules.Detent.HALF && now != SheetRules.Detent.HALF) setExpanded(true)
        select(id)
    }

    /** A row's Trip badge: that Trip, on the Trips tab, the sheet down so its tracks show. */
    private fun openTrip(id: String) {
        setExpanded(false)
        onOpenTrip(id)
    }

    internal companion object {
        /** How long a list load runs before the progress bar shows. */
        const val PROGRESS_DELAY_MS = 300L

        /** About twelve rows, then a dropdown's list scrolls ([TrackFilters]). */
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
