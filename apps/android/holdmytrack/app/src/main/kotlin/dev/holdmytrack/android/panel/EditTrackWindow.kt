package dev.holdmytrack.android.panel

import android.view.View
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.TextView
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.android.material.textfield.TextInputEditText
import com.google.android.material.textfield.TextInputLayout
import androidx.appcompat.widget.TooltipCompat
import dev.holdmytrack.android.R
import dev.holdmytrack.android.map.EditPreview
import dev.holdmytrack.android.map.PhotoMarkerOverlay
import dev.holdmytrack.android.net.FailureText
import dev.holdmytrack.android.net.Track
import dev.holdmytrack.android.net.ApiException
import dev.holdmytrack.android.net.HoldMyTrackApi
import dev.holdmytrack.android.net.Photo
import dev.holdmytrack.android.net.RoutePoint
import dev.holdmytrack.android.recording.TrackTypePicker
import dev.holdmytrack.android.recording.RecordingTypes
import dev.holdmytrack.android.recording.TypeCount
import dev.holdmytrack.android.recording.TypeSearch

/**
 * The Edit window, after the web's `apps/web/src/ui/EditTrackWindow.tsx` (`docs/SPEC.md`
 * FR-5.5, FR-5.7, FR-15): a card over the top of the map, opened from the Tracks
 * toolbar's Edit over its target, with three tabs behind one Save and Cancel.
 *
 *  - **Track**: one track edits Type, Name and Description; several edit Type only —
 *    Name and Description have nothing to set consistently across different tracks, so
 *    they're disabled with a note saying why rather than silently skipped.
 *  - **Route** ([RouteEditor]): one track with a finished track, else dimmed, a tap saying
 *    why under the tabs.
 *    Opening it the first time starts the map's track session ([onStartRoute]: the other
 *    tracks away, the camera on this one), which lasts until the window closes.
 *  - **Photos** ([PhotosTab]): one track with a track, else dimmed like Route. Its
 *    changes are a draft, like the route edit, written by the same Save.
 *
 * Save writes what changed — the fields first (one `PATCH /v2/tracks/{id}` each, one after
 * another, a group's resending each track's own name and description), then the photos,
 * then the route edit — and closes; a refusal keeps the window open with the server's reason,
 * a retried Save skips what already went, and a later step failing still reports the earlier
 * ones saved. Cancel writes nothing; Back does the same, but asks first while there are photo
 * changes, which can be a lot of picking and sliding to lose to a reflex.
 */
class EditTrackWindow(
    private val card: View,
    /** The Route tab opened on [Track] for the first time. */
    private val onStartRoute: (Track) -> Unit,
    /** The route editor's overlay — see [RouteEditor]. */
    onDrawRoute: (visible: List<RoutePoint>?, lo: Int, hi: Int, preview: EditPreview, split: Int?) -> Unit,
    /** Add photos: open the system photo picker, and hand what's picked to [photosTab]. */
    onPickPhotos: () -> Unit,
    /** The Photos tab's draft on the map — see [PhotosTab]. */
    onPhotoOverlay: (PhotoMarkerOverlay?) -> Unit,
    /** The tab showing changed — the map hides the photos while the Route tab has it. */
    private val onTabChanged: () -> Unit,
    /** Called once the window closes: whether anything was written, whether that included a
     *  route edit, which leaves the track Pending until its reprocess lands, and whether any
     *  photo was written, so the map reads them again. */
    private val onClose: (saved: Boolean, trackApplied: Boolean, photosSaved: Boolean) -> Unit,
) {
    private val context = card.context
    private val res = context.resources

    private val title: TextView = card.findViewById(R.id.edit_title)
    private val subtitle: TextView = card.findViewById(R.id.edit_subtitle)
    private val typeLayout: TextInputLayout = card.findViewById(R.id.edit_type_layout)
    private val typeField: TextInputEditText = card.findViewById(R.id.edit_type)
    private val nameLayout: TextInputLayout = card.findViewById(R.id.edit_name_layout)
    private val nameField: TextInputEditText = card.findViewById(R.id.edit_name)
    private val descriptionLayout: TextInputLayout = card.findViewById(R.id.edit_description_layout)
    private val descriptionField: TextInputEditText = card.findViewById(R.id.edit_description)
    private val multiNote: View = card.findViewById(R.id.edit_multi_note)
    private val error: TextView = card.findViewById(R.id.edit_error)
    private val cancel: Button = card.findViewById(R.id.edit_cancel)
    private val save: Button = card.findViewById(R.id.edit_save)
    private val tabTrack: TextView = card.findViewById(R.id.edit_tab_track)
    private val tabRoute: TextView = card.findViewById(R.id.edit_tab_route)
    private val routeDot: View = card.findViewById(R.id.edit_tab_route_dot)
    private val tabPhotos: TextView = card.findViewById(R.id.edit_tab_photos)
    private val photosCount: TextView = card.findViewById(R.id.edit_tab_photos_count)
    private val photosDot: View = card.findViewById(R.id.edit_tab_photos_dot)
    private val tabBlocked: TextView = card.findViewById(R.id.edit_tab_blocked)
    private val trackPanel: View = card.findViewById(R.id.edit_track_panel)
    private val routePanel: View = card.findViewById(R.id.edit_route_panel)
    private val photosPanel: View = card.findViewById(R.id.edit_photos_panel)

    /** The Route tab's editor — `MapFragment` hands it Delete point's map taps. */
    val routeEditor = RouteEditor(routePanel, onDrawRoute) { renderTabs() }

    /** The Photos tab — `MapFragment` hands it the saved photos and what the picker returns. */
    val photosTab = PhotosTab(photosPanel, onPickPhotos, onPhotoOverlay) {
        renderTabs()
        // A change to the photos answers whatever Save last refused about them.
        if (!saving) showError(null)
    }

    private var tab = EditTab.TRACK
    private var trackStarted = false

    /** Why the Route tab can't open, or null when it can. */
    private var trackUnavailable: String? = null

    /** Why the Photos tab can't open, or null when it can. */
    private var photosUnavailable: String? = null
    private var tracks: List<Track> = emptyList()
    private var known: List<TypeCount> = emptyList()

    /** The raw `track_type` the Type field holds — the field itself shows its label. Empty
     *  for a group of mixed types until one is picked: empty keeps each track's own. */
    private var trackType = ""

    /** The group's tracks don't all share one type. */
    private var mixedTypes = false
    private var saving = false

    /** "Saving photos n of m…" while the photos are written. */
    private var photoProgress: Pair<Int, Int>? = null

    /** Set once the fields are written, so a Save retried after a failure doesn't write them
     *  twice, and a Cancel after one still reports that something changed. */
    private var fieldsSaved = false

    val isOpen: Boolean
        get() = card.visibility == View.VISIBLE

    /** The Route tab is the one showing — the photos are off the map meanwhile. */
    val showingRoute: Boolean
        get() = isOpen && tab == EditTab.ROUTE

    /** The one track the window is open on, or null for a group. */
    val single: Track?
        get() = tracks.singleOrNull()?.takeIf { isOpen }

    init {
        typeField.setOnClickListener { openTypePicker() }
        typeLayout.setEndIconOnClickListener { openTypePicker() }
        cancel.setOnClickListener { close() }
        save.setOnClickListener { save() }
        tabTrack.setOnClickListener { showTab(EditTab.TRACK) }
        tabRoute.setOnClickListener { showTab(EditTab.ROUTE) }
        tabPhotos.setOnClickListener { showTab(EditTab.PHOTOS) }
    }

    /** A tab that can't be used says why under the tabs, and the open one stays. */
    private fun showTab(next: EditTab) {
        val reason = EditAvailability.tapped(next, route = trackUnavailable, photos = photosUnavailable)
        tabBlocked.text = reason
        tabBlocked.visibility = if (reason != null) View.VISIBLE else View.GONE
        if (reason != null) return
        tab = next
        if (next == EditTab.ROUTE) {
            val single = tracks.single()
            if (!trackStarted) {
                trackStarted = true
                onStartRoute(single)
            }
            routeEditor.open(single)
        } else {
            routeEditor.hide()
        }
        if (next == EditTab.PHOTOS) photosTab.open(tracks.single())
        photosTab.active = next == EditTab.PHOTOS
        hideKeyboard()
        renderTabs()
        onTabChanged()
    }

    /** The selected tab underlined, the others dimmed; one that can't apply dimmer still,
     *  saying why on a long press and in its description, as the web's disabled tab and its
     *  title. It stays enabled, so a tap reaches [showTab] and says why too. */
    private fun renderTabs() {
        val unavailable = mapOf(EditTab.ROUTE to trackUnavailable, EditTab.PHOTOS to photosUnavailable)
        for ((view, which) in listOf(tabTrack to EditTab.TRACK, tabRoute to EditTab.ROUTE, tabPhotos to EditTab.PHOTOS)) {
            val selected = tab == which
            if (selected) view.setBackgroundResource(R.drawable.bg_panel_tab_selected) else view.background = null
            view.alpha = when {
                selected -> 1f
                unavailable[which] != null -> DISABLED_TAB_ALPHA
                else -> UNSELECTED_TAB_ALPHA
            }
            view.isSelected = selected
        }
        tabRoute.contentDescription = trackUnavailable?.let { res.getString(R.string.edit_tab_route) + ". " + it }
            ?: if (routeEditor.changed) res.getString(R.string.edit_route_unsaved) else null
        TooltipCompat.setTooltipText(tabRoute, trackUnavailable)
        routeDot.visibility = if (routeEditor.changed) View.VISIBLE else View.GONE

        val photosChanged = !photosTab.draft.isEmpty
        val count = photosTab.count
        tabPhotos.contentDescription = photosUnavailable?.let { res.getString(R.string.photos_tab) + ". " + it }
            ?: listOfNotNull(
                res.getString(if (photosChanged) R.string.photos_unsaved else R.string.photos_tab),
                count.takeIf { it > 0 }?.toString(),
            ).joinToString(", ")
        TooltipCompat.setTooltipText(tabPhotos, photosUnavailable)
        photosCount.text = count.toString()
        photosCount.visibility = if (photosUnavailable == null && count > 0) View.VISIBLE else View.GONE
        photosCount.alpha = tabPhotos.alpha
        photosDot.visibility = if (photosChanged) View.VISIBLE else View.GONE

        trackPanel.visibility = if (tab == EditTab.TRACK) View.VISIBLE else View.GONE
        routePanel.visibility = if (tab == EditTab.ROUTE) View.VISIBLE else View.GONE
        photosPanel.visibility = if (tab == EditTab.PHOTOS) View.VISIBLE else View.GONE
    }

    /**
     * Opens over [group] — at least one. [knownTypes] is what the Type picker lists: the
     * range's types with how many of its tracks use each, the same facets the Type filter
     * is built from, as on the web.
     */
    fun open(group: List<Track>, knownTypes: List<TypeFacet>) {
        tracks = group
        known = knownTypes.map { TypeCount(it.type, it.count) }
        val single = group.singleOrNull()
        fieldsSaved = false
        saving = false
        photoProgress = null
        mixedTypes = group.any { it.trackType != group.first().trackType }
        trackType = if (mixedTypes) "" else group.first().trackType
        title.text = if (single != null) {
            res.getString(R.string.edit_title_one)
        } else {
            res.getQuantityString(R.plurals.edit_title_many, group.size, group.size)
        }
        subtitle.text = if (single != null) {
            single.name?.trim()?.takeIf { it.isNotEmpty() } ?: PanelFormat.startedAt(res, single.startedAt, single.timezone)
        } else {
            res.getString(R.string.edit_multi_subtitle)
        }
        typeField.setText(if (trackType.isEmpty()) "" else TrackTypes.label(trackType))
        // "Mixed types" stands in the empty field, shown without focus, until a type is picked.
        typeLayout.isExpandedHintEnabled = !mixedTypes
        typeLayout.placeholderText = if (mixedTypes) res.getString(R.string.edit_type_mixed) else null
        nameField.setText(single?.name.orEmpty())
        descriptionField.setText(single?.description.orEmpty())
        nameLayout.isEnabled = single != null
        descriptionLayout.isEnabled = single != null
        multiNote.visibility = if (single == null) View.VISIBLE else View.GONE
        trackUnavailable = EditAvailability.track(group)?.let { res.getString(blockMessage(it, R.string.edit_route_check_one)) }
        photosUnavailable = EditAvailability.photos(group)?.let { res.getString(blockMessage(it, R.string.photos_check_one)) }
        trackStarted = false
        tab = EditTab.TRACK
        tabBlocked.visibility = View.GONE
        showError(null)
        renderBusy()
        renderTabs()
        card.visibility = View.VISIBLE
    }

    /** [block]'s message; [checkOne] is the tab's own for a group. */
    private fun blockMessage(block: EditBlock, checkOne: Int): Int = when (block) {
        EditBlock.CHECK_ONE -> checkOne
        EditBlock.PENDING -> R.string.edit_route_processing
        EditBlock.PRIVATE -> R.string.track_private_note
        EditBlock.NO_ORIGINAL -> R.string.edit_route_no_original
        EditBlock.BAD_TIMES -> R.string.edit_route_bad_times
    }

    /** The saved photos of the one track the window is open on, or why they couldn't be read
     *  — `MapFragment` owns them, since they're also the map's markers. */
    fun setPhotos(photos: List<Photo>, failure: String?) = photosTab.setPhotos(photos, failure)

    /** Cancel: nothing more is written. */
    fun close() {
        if (saving) return
        finish(trackApplied = false)
    }

    /** Back: Cancel, but asking first while there are photo changes. */
    fun back() {
        if (saving) return
        if (photosTab.draft.isEmpty) {
            close()
            return
        }
        MaterialAlertDialogBuilder(context, R.style.ThemeOverlay_HoldMyTrack_Dialog_Destructive)
            .setTitle(R.string.photos_discard_title)
            .setMessage(R.string.photos_discard_message)
            .setPositiveButton(R.string.photos_discard) { _, _ -> close() }
            .setNegativeButton(R.string.photos_keep_editing, null)
            .show()
    }

    private fun openTypePicker() {
        if (saving) return
        TrackTypePicker.show(context, trackType, known) { picked ->
            trackType = picked
            typeField.setText(TrackTypes.label(picked))
            showError(null)
        }
    }

    private fun save() {
        val single = tracks.singleOrNull()
        val type = trackType.trim()
        val name = nameField.text?.toString().orEmpty().trim()
        val description = descriptionField.text?.toString().orEmpty()
        val invalid = when {
            type.isEmpty() && !mixedTypes -> res.getString(R.string.edit_type_required)
            TypeSearch.codePoints(type) > MAX_TYPE -> res.getQuantityString(R.plurals.edit_type_too_long, MAX_TYPE, MAX_TYPE)
            TypeSearch.codePoints(name) > MAX_NAME -> res.getQuantityString(R.plurals.edit_name_too_long, MAX_NAME, MAX_NAME)
            TypeSearch.codePoints(description) > MAX_DESCRIPTION -> res.getQuantityString(R.plurals.edit_description_too_long, MAX_DESCRIPTION, MAX_DESCRIPTION)
            else -> null
        }
        if (invalid != null) {
            showError(invalid)
            showTab(EditTab.TRACK)
            return
        }
        // Every new photo needs its place before anything is written, and a caption in bounds.
        photosTab.invalid()?.let {
            showError(it)
            showTab(EditTab.PHOTOS)
            return
        }
        val changed = if (single != null) {
            type != single.trackType || name != single.name.orEmpty() || description != single.description.orEmpty()
        } else {
            type.isNotEmpty() && tracks.any { it.trackType != type }
        }
        if (!changed || fieldsSaved) {
            savePhotos()
            return
        }
        saving = true
        showError(null)
        renderBusy()
        hideKeyboard()
        // One at a time, as the web does: a group is a handful of rows picked by hand.
        val writes = tracks.map { track ->
            if (single != null) {
                Triple(track.id, name, description)
            } else {
                Triple(track.id, track.name.orEmpty(), track.description.orEmpty())
            }
        }
        writeNext(writes, 0, type)
    }

    private fun writeNext(writes: List<Triple<String, String, String>>, index: Int, type: String) {
        if (index == writes.size) {
            fieldsSaved = true
            savePhotos()
            return
        }
        val (id, name, description) = writes[index]
        HoldMyTrackApi.updateTrack(id, type, name, description) { result ->
            result.onSuccess { writeNext(writes, index + 1, type) }
                .onFailure { failure ->
                    saving = false
                    // A group that failed partway has written some rows; the list reload on
                    // close shows which.
                    if (index > 0) fieldsSaved = true
                    renderBusy()
                    showError(FailureText.of(failure, res.getString(R.string.edit_save_failed)))
                }
        }
    }

    /** The photo draft, once the fields are in — when the Photos tab changed anything. */
    private fun savePhotos() {
        val single = tracks.singleOrNull()
        if (single == null || photosTab.draft.isEmpty) {
            saveRoute()
            return
        }
        saving = true
        showError(null)
        hideKeyboard()
        renderBusy()
        photosTab.save(single.id, onProgress = { done, total ->
            photoProgress = done to total
            renderBusy()
        }) { failure ->
            photoProgress = null
            if (failure == null) {
                saveRoute()
                return@save
            }
            saving = false
            renderBusy()
            showError(FailureText.of(failure, res.getString(R.string.edit_save_failed)))
        }
    }

    /** The route edit, once the fields and photos are in — when the Route tab changed anything. */
    private fun saveRoute() {
        val single = tracks.singleOrNull()
        if (single == null || !routeEditor.changed) {
            finish(trackApplied = false)
            return
        }
        saving = true
        renderBusy()
        sendRoute(single.id, allowHidden = false)
    }

    private fun sendRoute(id: String, allowHidden: Boolean) {
        saving = true
        renderBusy()
        HoldMyTrackApi.routeEdit(id, routeEditor.pending, routeEditor.splitAt, allowHidden) { result ->
            result.onSuccess { finish(trackApplied = true) }
                .onFailure { failure ->
                    saving = false
                    renderBusy()
                    if ((failure as? ApiException)?.errorCode == HoldMyTrackApi.SPLIT_HIDES_PART) {
                        // Everything before the track is written; the question is the split alone.
                        confirmHiddenSplit(id, failure.message.orEmpty())
                        return@onFailure
                    }
                    showError(FailureText.of(failure, res.getString(R.string.edit_save_failed)))
                }
        }
    }

    /** A split leaving one part inside a Private location: the server's explanation, and the
     *  choice to go ahead (`docs/SPEC.md` FR-5.9). */
    private fun confirmHiddenSplit(id: String, message: String) {
        MaterialAlertDialogBuilder(context, R.style.ThemeOverlay_HoldMyTrack_Dialog)
            .setTitle(R.string.edit_route_split_hidden_title)
            .setMessage(message)
            .setPositiveButton(R.string.edit_route_split_hidden_confirm) { _, _ -> sendRoute(id, allowHidden = true) }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    private fun finish(trackApplied: Boolean) {
        saving = false
        hideKeyboard()
        routeEditor.close()
        val photosSaved = photosTab.photosSaved
        photosTab.close()
        card.visibility = View.GONE
        onClose(fieldsSaved || trackApplied, trackApplied, photosSaved)
    }

    private fun renderBusy() {
        save.isEnabled = !saving
        cancel.isEnabled = !saving
        val progress = photoProgress
        save.text = when {
            progress != null -> res.getString(R.string.photos_saving_n, minOf(progress.first + 1, progress.second), progress.second)
            saving -> res.getString(R.string.edit_saving)
            else -> res.getString(R.string.edit_save)
        }
        typeLayout.isEnabled = !saving
        nameField.isEnabled = !saving && tracks.size == 1
        descriptionField.isEnabled = !saving && tracks.size == 1
        routeEditor.busy = saving
        photosTab.busy = saving
    }

    private fun showError(message: String?) {
        error.text = message
        error.visibility = if (message == null) View.GONE else View.VISIBLE
    }

    private fun hideKeyboard() {
        val imm = context.getSystemService(InputMethodManager::class.java)
        imm?.hideSoftInputFromWindow(card.windowToken, 0)
        card.findFocus()?.clearFocus()
    }

    private companion object {
        /** The server's own bounds (`tracks.go`'s maxTrackTypeLen and friends). */
        const val MAX_TYPE = TrackTypePicker.MAX_LENGTH
        const val MAX_NAME = 200
        const val MAX_DESCRIPTION = 2000
        const val UNSELECTED_TAB_ALPHA = 0.45f
        const val DISABLED_TAB_ALPHA = 0.3f
    }
}
