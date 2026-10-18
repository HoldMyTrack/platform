package dev.holdmytrack.android.map

import android.graphics.PointF
import android.graphics.RectF
import dev.holdmytrack.android.sync.Candidate
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.Style
import org.maplibre.android.style.expressions.Expression
import org.maplibre.android.style.layers.LineLayer
import org.maplibre.android.style.layers.Property
import org.maplibre.android.style.layers.PropertyFactory
import org.maplibre.android.style.layers.SymbolLayer
import org.maplibre.android.style.sources.GeoJsonSource
import org.maplibre.geojson.Feature
import org.maplibre.geojson.FeatureCollection
import org.maplibre.geojson.LineString
import org.maplibre.geojson.Point

/**
 * The Sync tab's candidates on the map (`docs/SPEC.md` FR-3.6): every activity listed there,
 * drawn dashed from the phone's own data — none of it is on the server yet — and the one picked
 * on the list or the map as the Map tab draws a selected activity: solid and wider over a dark
 * halo, coloured by pace ([Candidate.metrics], [TrackBands]). One GeoJSON source
 * whose layers filter on a `role` property, and one for the bands, all under the basemap's
 * labels, as [TrackEditOverlay] is. The lines are the candidates' simplified ones ([Candidate.line]).
 */
object SyncCandidatesOverlay {

    private const val SOURCE_ID = "sync-candidates"
    private const val BAND_SOURCE_ID = "sync-candidates-bands"
    private const val HALO_LAYER_ID = "sync-candidates-halo"
    private const val LINE_LAYER_ID = "sync-candidates-line"
    private const val HIGHLIGHT_LAYER_ID = "sync-candidates-highlight"
    private const val BAND_LAYER_ID = "sync-candidates-bands"

    /** How far from a tap a line still counts as tapped — the tracks' own tolerance, in dp. */
    private const val TAP_TOLERANCE_DP = 14f

    fun ensure(style: Style) {
        if (style.getSource(SOURCE_ID) == null) style.addSource(GeoJsonSource(SOURCE_ID))
        if (style.getSource(BAND_SOURCE_ID) == null) style.addSource(GeoJsonSource(BAND_SOURCE_ID))
        val beforeId = style.layers.firstOrNull { it is SymbolLayer }?.id
        fun add(layer: LineLayer) {
            if (style.getLayer(layer.id) != null) return
            // From the zoom tracks start at, like everything else but Fog and Heatmap (`docs/SPEC.md` FR-4.15).
            layer.minZoom = MapOverlays.TRACKS_MIN_ZOOM
            if (beforeId != null) style.addLayerBelow(layer, beforeId) else style.addLayer(layer)
        }
        fun role(name: String) = Expression.eq(Expression.get("role"), name)
        // Halo first, then the dashed lines, then the picked line and its bands over them: the
        // halo, picked line and bands as the layers document draws a selected activity's.
        add(LineLayer(HALO_LAYER_ID, SOURCE_ID).withFilter(role("highlight")).withProperties(*MapLayers.propertiesOf(style, "casing")))
        add(
            LineLayer(LINE_LAYER_ID, SOURCE_ID).withFilter(role("line")).withProperties(
                PropertyFactory.lineCap(Property.LINE_CAP_BUTT),
                PropertyFactory.lineJoin(Property.LINE_JOIN_ROUND),
                PropertyFactory.lineWidth(3f),
                PropertyFactory.lineOpacity(0.85f),
                PropertyFactory.lineDasharray(arrayOf(1.5f, 1.5f)),
            ).apply { MapLayers.color(style, "track")?.let { setProperties(PropertyFactory.lineColor(it)) } },
        )
        add(LineLayer(HIGHLIGHT_LAYER_ID, SOURCE_ID).withFilter(role("highlight")).withProperties(*MapLayers.propertiesOf(style, "focused")))
        add(LineLayer(BAND_LAYER_ID, BAND_SOURCE_ID).withProperties(*MapLayers.propertiesOf(style, "pace-bands")))
    }

    /** Draws [candidates], [highlight] (a [Candidate.key]) picked out over the rest, in its pace bands. */
    fun set(style: Style, candidates: List<Candidate>, highlight: String?) {
        ensure(style)
        val source = style.getSourceAs<GeoJsonSource>(SOURCE_ID) ?: return
        // The picked one last, so it's drawn over its neighbours.
        val ordered = candidates.sortedBy { it.key == highlight }
        val features = ordered.filter { it.line.size >= 2 }.map { candidate ->
            Feature.fromGeometry(LineString.fromLngLats(candidate.line.map { Point.fromLngLat(it[0], it[1]) })).apply {
                addStringProperty("role", if (candidate.key == highlight) "highlight" else "line")
                addStringProperty("key", candidate.key)
            }
        }
        source.setGeoJson(FeatureCollection.fromFeatures(features))
        val bands = candidates.firstOrNull { it.key == highlight }
            ?.let { MapOverlays.bandFeatures(it.metrics, TrackBands.runs(it.metrics.map { point -> point.speedMps })) }.orEmpty()
        style.getSourceAs<GeoJsonSource>(BAND_SOURCE_ID)?.setGeoJson(FeatureCollection.fromFeatures(bands))
    }

    fun clear(style: Style) {
        style.getSourceAs<GeoJsonSource>(SOURCE_ID)?.setGeoJson(FeatureCollection.fromFeatures(emptyList()))
        style.getSourceAs<GeoJsonSource>(BAND_SOURCE_ID)?.setGeoJson(FeatureCollection.fromFeatures(emptyList()))
    }

    /** The key of the candidate drawn under [screen], if any. */
    fun keyAt(map: MapLibreMap, screen: PointF, density: Float): String? {
        val tolerance = TAP_TOLERANCE_DP * density
        val box = RectF(screen.x - tolerance, screen.y - tolerance, screen.x + tolerance, screen.y + tolerance)
        return map.queryRenderedFeatures(box, HIGHLIGHT_LAYER_ID, LINE_LAYER_ID)
            .firstNotNullOfOrNull { it.getStringProperty("key") }
    }
}
