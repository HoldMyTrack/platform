package dev.holdmytrack.android.map

import android.net.Uri
import dev.holdmytrack.android.net.PaceBand
import dev.holdmytrack.android.net.TrackMetricPoint
import dev.holdmytrack.android.net.TrackMetrics
import dev.holdmytrack.android.recording.RecordedPoint
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import org.maplibre.android.maps.Style
import org.maplibre.android.style.layers.CircleLayer
import org.maplibre.android.style.layers.LineLayer
import org.maplibre.android.style.layers.Property
import org.maplibre.android.style.layers.PropertyFactory
import org.maplibre.android.style.sources.GeoJsonSource
import org.maplibre.geojson.Feature
import org.maplibre.geojson.FeatureCollection
import org.maplibre.geojson.LineString
import org.maplibre.geojson.Point

/**
 * The three mutually exclusive views `docs/SPEC.md` FR-4.4 names — one toggle, not
 * three checkboxes. Both Fog and Heatmap hide the track lines: the veil or the heat already
 * shows where the user has been, and lines drawn on top of it read as noise rather than as extra
 * information.
 */
enum class MapMode { NORMAL, FOG, HEATMAP }

/** The three levels Fog and Heatmap draw at by zoom (`docs/IMPLEMENTATION.md` §4.2.4): whole
 *  countries, then whole states or provinces, then exactly where you've been. */
enum class ZoomTier { COUNTRY, REGION, CITY }

/**
 * The user layers on top of the served basemap, as the layers document draws them ([MapLayers]),
 * and what the app decides about them: the tracks' range or Story, which tracks are hidden and
 * selected, and when the tracks step aside. Also the live recording, drawn from the device.
 *
 * Every tile is behind `requireAuth` (`services/server/internal/httpapi/server.go`), which is
 * why they are attached only once the stored session is verified rather than at style load —
 * an unverified token would otherwise surface as a wall of 401s on tile requests.
 */
object MapOverlays {

    /** The track lines everyone taps: the layers document's `tracks-line`. */
    const val TRACKS_LAYER_ID = "tracks-line"

    /** The selected activity's pace bands, the document's `track-bands` group. */
    const val BAND_LAYER_ID = "track-bands-line"
    private const val BAND_SOURCE_ID = "track-bands"

    private const val TRACKS_SOURCE_ID = "tracks"

    /** What the tracks and their bands are, as groups to step aside. */
    private val TRACK_GROUPS = setOf("tracks", "track-bands")

    /**
     * Tracks draw from z4 inward (the document's tracks layers start there), and so does
     * everything the app draws over them: the Sync candidates, the Private location circles,
     * the photo markers. Mirrors `apps/web/src/map/config.ts`'s `TRACKS_MIN_ZOOM`.
     */
    const val TRACKS_MIN_ZOOM = 4f

    /** The open Story the tracks are narrowed to, or null — kept for every new tracks URL. */
    private var trackStory: String? = null

    /**
     * Bumped by [refreshTracks] and sent as `v` (the server ignores it), the web's
     * `tracksVersion`: every tile URL also carries the account's tile version as `cv`, under
     * which MapLibre keeps the tile for good, and a change the app hasn't read a new version for
     * yet (a type edit) would otherwise be answered from that cache.
     */
    private var tracksVersion = 0

    /** A track is being edited (`TrackEditOverlay`): every other track and the bands step
     *  aside for it, as the web's `setMapMode(…, editingTrack)` has them. */
    private var editingTrack = false

    /** The Sync tab shows: the account's tracks and bands step aside, so the map draws only
     *  what's on offer (`SyncCandidatesOverlay`), not a slice of what's already synced. */
    private var syncing = false

    /** A recording is in progress ([setRecording]). */
    private var recording = false

    private const val LIVE_TRACK_SOURCE_ID = "live-track"
    private const val LIVE_TRACK_LAYER_ID = "live-track-line"
    private const val LIVE_POSITION_SOURCE_ID = "live-position"
    private const val LIVE_POSITION_LAYER_ID = "live-position-dot"
    private const val LIVE_TRACK_WIDTH = 4f
    private const val LIVE_POSITION_RADIUS = 6f

    /**
     * Applies [doc] to [style] without the groups [excluded], the tracks narrowed to [range]
     * (null draws the whole history), and every group as [mode] shows it. Safe to call against a
     * style that already has them: a style reload (a day/night flavor swap) discards custom
     * layers, so this has to be re-runnable rather than one-shot.
     *
     * Only the tracks tile carries a filter: `from`/`to`, or an open Story's `story` in their
     * place ([setTrackStory]) — the same as the web, whose date range and Story narrow the
     * tracks alone: Fog and Heatmap show coverage no filter narrows
     * (`docs/SPEC.md` FR-4.2, FR-4.3). The Activities panel's TYPE/DISTANCE filters, hidden
     * set and selection are vars the layers bind ([setTrackFilter]).
     *
     * [satellite] says imagery is drawn, which picks the views over it.
     */
    fun attach(
        style: Style,
        doc: MapLayersDoc.Doc,
        mode: MapMode,
        range: DateRange?,
        satellite: Boolean,
        story: String?,
        excluded: Set<String> = emptySet(),
    ) {
        trackStory = story
        MapLayers.update(null) { it.copy(mode = mode, satellite = satellite, queries = it.queries + (TRACKS_SOURCE_ID to trackQuery(range))) }
        MapLayers.attach(style, doc, excluded)
        setMode(style, mode)
        // The live line in the tracks' own color.
        MapLayers.color(style, "track")?.let { color ->
            style.getLayer(LIVE_TRACK_LAYER_ID)?.setProperties(PropertyFactory.lineColor(color))
            style.getLayer(LIVE_POSITION_LAYER_ID)?.setProperties(PropertyFactory.circleColor(color))
        }
    }

    /**
     * Draws [metrics]' pace bands — the selected activity's, `GET /v1/activities/{id}/track-metrics` —
     * one line per run the server worked out, each with its `band` for the layer to colour. The
     * web's `setTrackBands`.
     */
    fun setTrackBands(style: Style, metrics: TrackMetrics) {
        style.getSourceAs<GeoJsonSource>(BAND_SOURCE_ID)?.setGeoJson(FeatureCollection.fromFeatures(bandFeatures(metrics.points, metrics.bands)))
    }

    /** [bands]' runs of [points] as lines, each with its `band`. */
    fun bandFeatures(points: List<TrackMetricPoint>, bands: List<PaceBand>): List<Feature> = bands.map { run ->
        val line = LineString.fromLngLats(points.subList(run.start, run.end + 1).map { Point.fromLngLat(it.lon, it.lat) })
        Feature.fromGeometry(line).apply { addNumberProperty("band", run.band) }
    }

    fun clearTrackBands(style: Style) {
        style.getSourceAs<GeoJsonSource>(BAND_SOURCE_ID)?.setGeoJson(FeatureCollection.fromFeatures(emptyList()))
    }

    /** The tracks tiles fetched again for [range] — after a delete, or a reprocess landing. */
    fun refreshTracks(style: Style, range: DateRange?) {
        tracksVersion += 1
        setTrackRange(style, range)
    }

    /** Narrows the tracks to [range]: a new query, which [MapLayers] takes by replacing the
     *  tracks source, since MapLibre Native can't change a vector source's URL in place. */
    fun setTrackRange(style: Style, range: DateRange?) {
        MapLayers.update(style) { it.copy(queries = it.queries + (TRACKS_SOURCE_ID to trackQuery(range))) }
    }

    /** Narrows the tracks to [story]'s activities, all of them — the tile's `story` filter
     *  (`docs/SPEC.md` FR-14.4), with no range — or, with null, back to [range]'s. */
    fun setTrackStory(style: Style, story: String?, range: DateRange?) {
        trackStory = story
        setTrackRange(style, range)
    }

    /**
     * Leaves [hidden] off the map — filtered out by TYPE/DISTANCE, hidden with Show/Hide, or
     * Pending — and draws [selected] bold over its halo, unless it's one of those: the document's
     * `hidden` and `focused` vars. The web's `setHiddenTracks` and `setSelectedTracks`.
     */
    fun setTrackFilter(style: Style, hidden: Set<String>, selected: Set<String>) {
        fun ids(set: Set<String>) = JsonArray(set.sorted().map(::JsonPrimitive))
        MapLayers.update(style) { it.copy(vars = it.vars + mapOf("hidden" to ids(hidden), "focused" to ids(selected))) }
    }

    /** See [editingTrack]. */
    fun setEditingTrack(style: Style, editing: Boolean, mode: MapMode) {
        editingTrack = editing
        setMode(style, mode)
    }

    /** See [syncing]. */
    fun setSyncing(style: Style, on: Boolean, mode: MapMode) {
        syncing = on
        setMode(style, mode)
    }

    /** [mode]'s view, labels included ([MapLayers]), the tracks stepping aside while a track is
     *  edited, the Sync tab shows or a recording runs. */
    fun setMode(style: Style, mode: MapMode) {
        val aside = editingTrack || syncing || recording
        MapLayers.update(style) { it.copy(mode = if (recording) MapMode.NORMAL else mode, hiddenGroups = it.hiddenGroups + ("tracksAside" to if (aside) TRACK_GROUPS else emptySet())) }
    }

    /**
     * While a recording is in progress the map shows that recording and nothing else — no
     * history tracks, no fog, no heatmap, whichever [mode] was selected. Ending it restores
     * [mode]. The live track ([attachLiveTrack]) is always on and simply empty when nothing is
     * recording.
     */
    fun setRecording(style: Style, recording: Boolean, mode: MapMode) {
        this.recording = recording
        setMode(style, mode)
    }

    /**
     * The in-progress recording's line and a dot at its latest fix, drawn from the points
     * `RecordingService` holds on the device — not from the server, which has never seen them.
     * Added on top of everything, labels included: it's the one thing on the map that
     * matters while recording. Unlike [attach] this needs no session, so it goes on at style
     * load, in the tracks' color once the layers document is on ([attach]). Re-runnable, like
     * [attach].
     */
    fun attachLiveTrack(style: Style) {
        if (style.getSource(LIVE_TRACK_SOURCE_ID) == null) style.addSource(GeoJsonSource(LIVE_TRACK_SOURCE_ID))
        if (style.getSource(LIVE_POSITION_SOURCE_ID) == null) style.addSource(GeoJsonSource(LIVE_POSITION_SOURCE_ID))
        val color = MapLayers.color(style, "track")
        if (style.getLayer(LIVE_TRACK_LAYER_ID) == null) {
            style.addLayer(
                LineLayer(LIVE_TRACK_LAYER_ID, LIVE_TRACK_SOURCE_ID).withProperties(
                    PropertyFactory.lineCap(Property.LINE_CAP_ROUND),
                    PropertyFactory.lineJoin(Property.LINE_JOIN_ROUND),
                    PropertyFactory.lineWidth(LIVE_TRACK_WIDTH),
                ).apply { color?.let { setProperties(PropertyFactory.lineColor(it)) } },
            )
        }
        if (style.getLayer(LIVE_POSITION_LAYER_ID) == null) {
            style.addLayer(
                CircleLayer(LIVE_POSITION_LAYER_ID, LIVE_POSITION_SOURCE_ID).withProperties(
                    PropertyFactory.circleRadius(LIVE_POSITION_RADIUS),
                    PropertyFactory.circleStrokeColor("#ffffff"),
                    PropertyFactory.circleStrokeWidth(2f),
                ).apply { color?.let { setProperties(PropertyFactory.circleColor(it)) } },
            )
        }
    }

    /** Redraws the live track from scratch — an empty list clears it. */
    fun updateLiveTrack(style: Style, points: List<RecordedPoint>) {
        val coordinates = points.map { Point.fromLngLat(it.lon, it.lat) }
        val empty = FeatureCollection.fromFeatures(emptyList())
        style.getSourceAs<GeoJsonSource>(LIVE_TRACK_SOURCE_ID)?.let { source ->
            if (coordinates.size < 2) source.setGeoJson(empty) else source.setGeoJson(LineString.fromLngLats(coordinates))
        }
        style.getSourceAs<GeoJsonSource>(LIVE_POSITION_SOURCE_ID)?.let { source ->
            val last = coordinates.lastOrNull()
            if (last == null) source.setGeoJson(empty) else source.setGeoJson(last)
        }
    }

    /** The query the app appends to the tracks tiles: an open Story whole, whatever the range
     *  (`docs/SPEC.md` FR-14.6), else the range, and the refresh counter. */
    private fun trackQuery(range: DateRange?): String = buildList {
        val story = trackStory
        if (story != null) {
            add("story=${Uri.encode(story)}")
        } else if (range != null) {
            add("from=${range.from}")
            add("to=${range.to}")
        }
        if (tracksVersion > 0) add("v=$tracksVersion")
    }.joinToString("&")
}
