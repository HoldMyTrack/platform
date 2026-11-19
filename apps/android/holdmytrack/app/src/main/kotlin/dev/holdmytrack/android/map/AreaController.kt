package dev.holdmytrack.android.map

import android.os.Bundle
import android.util.Log
import android.view.View
import androidx.fragment.app.Fragment
import dev.holdmytrack.android.R
import dev.holdmytrack.android.net.Track
import dev.holdmytrack.android.net.HoldMyTrackApi
import dev.holdmytrack.android.net.Session
import dev.holdmytrack.android.panel.TracksPanel
import dev.holdmytrack.android.panel.PanelState
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.Style
import java.text.NumberFormat

/**
 * What the list and the tracks show, bound to the views (`docs/SPEC.md` FR-5.11, FR-5.12): the
 * visible area's tracks under Dates, followed each time the camera settles from zoom 4 but
 * not after the app's own flights, the 1,000 cap drawn through the tracks' `capped` and `listed`
 * vars, Dates' dialog and its one flight, or a Trip through [MapSession]; the list's Pending rows
 * tracked ([PendingTracker]). The web's `useAreaList.ts` and `useDatesFlight.ts`.
 */
class AreaController(
    private val fragment: Fragment,
    host: View,
    private val session: MapSession,
    private val panelState: PanelState,
    private val panel: TracksPanel,
    private val map: () -> MapLibreMap?,
    /** The style once the user layers are on it. */
    private val style: () -> Style?,
    private val framer: () -> CameraFramer?,
    private val bands: PaceBands,
    private val coverage: CoverageController,
    private val recording: () -> Boolean,
    /** The panel's selection was reset: the map, the bands and the sheet's head follow. */
    private val onSelectionReset: () -> Unit,
    /** Shows or hides the capped notice, its text or null. */
    private val onCapped: (String?) -> Unit,
) {
    /** Reprocesses running, and the list read again while any is. */
    val pending = PendingTracker(host = { host }, reload = ::reloadList, finished = ::pendingFinished)

    /** The first and newest tracks' days: Dates' bounds. */
    private var earliest: String? = null
    private var latest: String? = null

    /** How many tracks the last area held, more than listed past the cap; null for a Trip. */
    private var total: Int? = null

    /** A View on map's track, to select once a list has it ([viewTrack]). */
    private var pendingFocusId: String? = null

    /** Bumped per list read, so only the latest one's answer lands. */
    private var request = 0

    private val res = host.resources
    private val unreachable = res.getString(R.string.map_unreachable)
    private val dialog = DatesDialog(fragment, ::setDates, ::clearDates)

    init {
        panel.onDatesTap = ::showDates
        renderDates()
    }

    // The camera.

    /** The camera settled: from zoom 4 the list follows it, unless the app moved it (a focused
     *  row, a Trip), or a recording, whose live line has the camera, or it already holds that
     *  view. An open Trip keeps the view for when it closes. */
    fun onCameraIdle() {
        if (framer()?.consumeAppFlight() == true || recording()) return
        followArea()
    }

    /** The list asked about the view as it is, unless it already was; [always] on closing a Trip
     *  and on a recording's end. */
    fun followArea(always: Boolean = false) {
        val instance = map() ?: return
        val b = instance.projection.visibleRegion.latLngBounds
        val (west, east) = BoxUnion.viewEdges(b.longitudeWest, b.longitudeEast)
        val moved = session.areaLoaded(AreaLoad.box(west, b.latitudeSouth, east, b.latitudeNorth))
        if (session.tripId != null) return
        if (moved || always || zoomedOut() != lastZoomedOut) reloadList()
    }

    private var lastZoomedOut = false

    private fun zoomedOut(): Boolean =
        AreaLoad.of(map()?.cameraPosition?.zoom ?: 0.0, 0, null).load == AreaLoad.Load.NONE

    // The list.

    /** Lists the open Trip's tracks, else the area's under Dates, in the panel; too far out
     *  the list is empty, asking nothing. Frames them when the session asked for a flight. */
    fun reloadList() {
        val trip = session.tripId
        val area = session.area
        val id = ++request
        val asked = Session.generation
        if (trip == null) {
            // Not until the opening view has asked about an area.
            area ?: return
            lastZoomedOut = zoomedOut()
            if (lastZoomedOut) {
                total = null
                panel.setZoomedOut()
                renderCap()
                // An empty list: held Pending rows are the Pending check's to finish.
                trackPending(emptyList())
                return
            }
        }
        panel.setLoading()
        val landed = { tracks: List<Track>, total: Int? ->
            if (id == request && Session.isCurrent(asked)) {
                this.total = total
                listed(tracks)
            }
        }
        val failed = { failure: Throwable ->
            if (id == request) {
                Log.w(TAG, "could not load the track list", failure)
                session.consumeFly()
                panel.setError(unreachable)
                // A failed read doesn't end the polling: a Pending row still has to be seen finishing.
                pending.readFailed()
            }
        }
        if (trip != null) {
            HoldMyTrackApi.tripTracks(trip) { result -> result.onSuccess { landed(it, null) }.onFailure(failed) }
        } else {
            HoldMyTrackApi.areaTracks(area, session.dates.after, session.dates.before) { result -> result.onSuccess { landed(it.tracks, it.total) }.onFailure(failed) }
        }
    }

    private fun listed(tracks: List<Track>) {
        panel.setTracks(tracks)
        renderCap()
        trackPending(tracks)
        pendingFocusId?.takeIf { id -> tracks.any { it.id == id } }?.let { id ->
            pendingFocusId = null
            panel.focusFromMap(id)
        }
        // A recording started since owns the camera.
        if (session.consumeFly() && !recording()) framer()?.flyTo(tracks.filter { !it.pending })
    }

    /** Past the cap the map draws only the listed tracks and says how many the area holds. */
    private fun renderCap() {
        val listed = panelState.tracks
        val capped = session.tripId == null &&
            AreaLoad.of(map()?.cameraPosition?.zoom ?: 0.0, listed.size, total).capped
        MapOverlays.setTrackCap(style(), capped, if (capped) listed.map { it.id } else emptyList())
        val count = NumberFormat.getIntegerInstance()
        onCapped(total?.takeIf { capped }?.let { res.getString(R.string.area_capped, count.format(listed.size), count.format(it)) })
    }

    /**
     * Pending rows ([PendingTracker]): a row starting or stopping Pending refetches the track tiles
     * and watches Fog until re-rendered; a finished one also reloads Dates' bounds.
     */
    private fun trackPending(tracks: List<Track>) {
        val change = pending.track(tracks)
        if (change.finished) pendingFinished(change.landed + change.left)
        else if (change.started) refreshPending()
    }

    /** Reprocesses finished, seen by a list or by the Pending check for rows it doesn't show. */
    private fun pendingFinished(ids: Set<String>) {
        // The selected track's reprocess landed: its metrics describe the old points.
        if (panelState.focused in ids) bands.update(refetch = true)
        refreshPending()
        reloadHistory()
        panel.tripsTab.reloadOpen()
    }

    private fun refreshPending() {
        style()?.let { MapOverlays.refreshTracks(it, session.dates) }
        coverage.watch()
    }

    // Dates.

    /** Dates' bounds, the first and newest tracks' days: on every return to the map and
     *  after an import, a delete or a sync, which can change them. */
    fun reloadHistory() {
        HoldMyTrackApi.trackDayPage(1, null) { result ->
            result.onSuccess { page ->
                earliest = page.earliest
                latest = page.days.lastOrNull()?.date
            }
        }
    }

    private val today: String get() = DateFilter.today(Session.timezone)

    private val bounds: DateFilter.Bounds get() = DateFilter.bounds(earliest, latest, today)

    private fun showDates() = dialog.show(session.dates, bounds, earliest, today)

    private fun setDates(end: DateFilter.End, value: String?) {
        val change = session.dates.setting(end, value, bounds)
        if (change.filter == session.dates) return
        session.setDates(change.filter, change.fly)
        datesChanged()
    }

    private fun clearDates() {
        if (session.dates.isAllTime) return
        session.setDates(DateFilter.ALL_TIME, fly = false)
        datesChanged()
    }

    /** Dates changed: their chip, the tracks, and the list, after a flight onto what they match
     *  when one was asked for. */
    private fun datesChanged() {
        dialog.update(session.dates)
        renderDates()
        style()?.let { MapOverlays.setTrackDates(it, session.dates) }
        if (session.consumeFly() && !recording()) datesFlight() else reloadList()
    }

    private fun renderDates() {
        val dates = session.dates
        val text = when (val label = dates.label) {
            DateFilter.Label.All -> res.getString(R.string.dates_name)
            is DateFilter.Label.Between -> res.getString(R.string.dates_between, DatesDialog.short(label.after, today), DatesDialog.short(label.before, today))
            is DateFilter.Label.After -> res.getString(R.string.dates_after_date, DatesDialog.short(label.after, today))
            is DateFilter.Label.Before -> res.getString(R.string.dates_before_date, DatesDialog.short(label.before, today))
        }
        panel.setDates(text, !dates.isAllTime)
    }

    /** Setting Dates moves the camera once onto what they match, wherever it is, asked for without
     *  an area, since the area holds only what's in view; the list then follows the new view.
     *  Nothing matched leaves the camera. */
    private fun datesFlight() {
        val dates = session.dates
        HoldMyTrackApi.areaTracks(null, dates.after, dates.before) { result ->
            if (dates != session.dates) return@areaTracks
            val box = BoxUnion.of(result.getOrNull()?.tracks.orEmpty().filter { !it.pending }.mapNotNull { it.bbox })
            if (box == null) {
                reloadList()
                return@areaTracks
            }
            // Asked about where it lands even if that's the view already asked about: Dates changed.
            framer()?.flyTo(box, onLanded = { followArea(always = true) }) ?: reloadList()
        }
    }

    // View on map and Trips.

    /**
     * A Sync history row's View on map: the track selected. Not listed, Dates become its [day]
     * (its local date where it was recorded), which flies the camera there, and the selection
     * waits for that list.
     */
    fun viewTrack(trackId: String, day: String) {
        if (session.tripId == null && panelState.tracks.any { it.id == trackId }) {
            panel.focusFromMap(trackId)
            return
        }
        pendingFocusId = trackId
        if (session.tripId != null) exitTrip()
        session.viewDay(day)
        datesChanged()
    }

    /** Opens Trip [id]: the panel's state resets, the tracks and the list become the Trip's
     *  tracks, and the camera fits them. */
    fun enterTrip(id: String) {
        session.enterTrip(id)
        onSelectionReset()
        panel.showTrips()
        panel.tripsTab.setOpen(id)
        style()?.let { MapOverlays.setTrackTrip(it, id, session.dates) }
        reloadList()
    }

    /** Closes the open Trip: back to the area and Dates, asked about wherever the map is now.
     *  The camera stays. */
    fun exitTrip() {
        session.exitTrip()
        panel.tripsTab.setOpen(null)
        onSelectionReset()
        style()?.let { MapOverlays.setTrackTrip(it, null, session.dates) }
        followArea(always = true)
    }

    /** Dates carried through a recreation. */
    fun restore(saved: Bundle?) {
        saved ?: return
        session.restore(DateFilter(saved.getString(STATE_AFTER), saved.getString(STATE_BEFORE)))
        renderDates()
    }

    fun save(out: Bundle) {
        out.putString(STATE_AFTER, session.dates.after)
        out.putString(STATE_BEFORE, session.dates.before)
    }

    fun release() = dialog.dismiss()

    private companion object {
        const val TAG = "HoldMyTrack"
        const val STATE_AFTER = "dates_after"
        const val STATE_BEFORE = "dates_before"
    }
}