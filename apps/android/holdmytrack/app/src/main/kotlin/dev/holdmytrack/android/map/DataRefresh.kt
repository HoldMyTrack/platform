package dev.holdmytrack.android.map

import dev.holdmytrack.android.panel.ActivitiesPanel
import dev.holdmytrack.android.panel.PanelState
import dev.holdmytrack.android.photos.PhotosController
import org.maplibre.android.maps.Style

/**
 * What the map reads again when activities change under it, as the web's `useDataRefresh.ts`: the
 * track tiles, the list and Dates' bounds ([AreaController]), the open Story, the bands, the photos,
 * and Fog once re-rendered ([CoverageController]).
 */
class DataRefresh(
    private val area: AreaController,
    private val session: MapSession,
    private val panel: ActivitiesPanel,
    private val panelState: PanelState,
    /** The style once the user layers are on it. */
    private val style: () -> Style?,
    private val coverage: CoverageController,
    private val bands: PaceBands,
    private val photos: PhotosController,
) {
    private fun refreshTracks() {
        style()?.let { MapOverlays.refreshTracks(it, session.dates) }
    }

    /** An activity taken out of the open Story: its track and row go, and its selection. The
     *  tile version moved, and the tiles follow. */
    fun afterRemovedFromStory(activityId: String) {
        if (panelState.focused == activityId) panel.clearFocus()
        photos.refresh(force = true)
        coverage.checkTileVersion()
        refreshTracks()
        area.reloadList()
    }

    /**
     * A Private location saved or deleted: the activities it touches are reprocessed. The list is
     * read at once, and everything again once the server drains, since a batch that finishes
     * before the first read never shows a row Pending.
     */
    fun afterPrivateLocations() {
        area.reloadList()
        coverage.watch {
            refreshTracks()
            area.reloadList()
            area.reloadHistory()
            bands.update(refetch = true)
            photos.refresh(force = true)
            panel.storiesTab.reloadOpen()
        }
    }

    /** A Story copy arrived (`docs/SPEC.md` FR-13.8): new activities, refreshed as after an upload. */
    fun afterStoryCopy() {
        refreshTracks()
        area.reloadList()
        area.reloadHistory()
        coverage.watch()
    }

    /** The Sync tab sent activities: the list, Dates' bounds and the tiles catch up. */
    fun afterSync() {
        area.reloadHistory()
        area.reloadList()
        // Tracks refetch at once; the tile version moves only after the coverage render.
        refreshTracks()
        coverage.checkTileVersion()
    }

    /** The toolbar's Delete finished: tracks, list and Dates' bounds read again, and Fog watched
     *  until re-rendered. Deleted ids leave the selection with the reload. */
    fun afterDelete(ids: List<String>) {
        if (ids.isEmpty()) return
        refreshTracks()
        area.reloadList()
        area.reloadHistory()
        coverage.watch()
        panel.storiesTab.reloadOpen()
        photos.refresh(force = true)
    }
}
