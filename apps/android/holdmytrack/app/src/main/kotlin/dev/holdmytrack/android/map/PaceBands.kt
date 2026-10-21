package dev.holdmytrack.android.map

import dev.holdmytrack.android.net.HoldMyTrackApi
import dev.holdmytrack.android.net.TrackMetrics
import dev.holdmytrack.android.panel.PanelState
import org.maplibre.android.maps.Style

/**
 * The selected activity's pace bands: its metrics fetched when the selection moves, again after
 * its reprocess lands, and dropped when it clears. Drawn while its track is drawn: not hidden,
 * filtered out or Pending (its metrics would show the old points), and not on the Sync tab, whose
 * picked candidate has its own (`map/SyncCandidatesOverlay`).
 */
/** [group]'s legend colors, `band-0` first. */
internal fun bandColors(group: MapLayersDoc.Group): List<String> =
    group.legend.keys.filter { it.startsWith("band-") }.sortedBy { it.removePrefix("band-").toIntOrNull() ?: 0 }.map { group.legend.getValue(it).color }

class PaceBands(
    private val panelState: PanelState,
    /** The style once the user layers are on it. */
    private val style: () -> Style?,
    private val onSyncTab: () -> Boolean,
    /** The bands' colors, slowest first, while they're drawn, else null: the panel's legend follows. */
    private val onShown: (List<String>?) -> Unit,
    /** A refetch after a reprocess: the photos may have moved along the new track too. */
    private val onRefetch: () -> Unit,
) {
    /** Null with nothing selected, and while a new selection's are loading. */
    private var metrics: TrackMetrics? = null
    private var metricsFor: String? = null

    /** The selection moved, or with [refetch] the selected activity's reprocess landed. */
    fun update(refetch: Boolean) {
        val focused = panelState.focused
        if (focused == null) {
            metrics = null
            metricsFor = null
            render()
            return
        }
        if (focused == metricsFor && !refetch) {
            render()
            return
        }
        if (refetch) onRefetch()
        metricsFor = focused
        if (!refetch) metrics = null
        render()
        HoldMyTrackApi.trackMetrics(focused) { result ->
            if (panelState.focused != focused) return@trackMetrics
            metrics = result.getOrNull()
            render()
        }
    }

    /** The bands the map draws, or null: the export's hidden map draws the same. */
    val drawn: TrackMetrics?
        get() = metrics?.takeIf { val focused = panelState.focused; focused == it.activityId && focused !in panelState.mapHidden && !onSyncTab() }

    fun render() {
        val loaded = style() ?: return
        val drawn = drawn
        if (drawn != null) MapOverlays.setTrackBands(loaded, drawn) else MapOverlays.clearTrackBands(loaded)
        onShown(drawn?.let { MapLayers.doc(loaded)?.group("track-bands")?.let(::bandColors) })
    }
}
