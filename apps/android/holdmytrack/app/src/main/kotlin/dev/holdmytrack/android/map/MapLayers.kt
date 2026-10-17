package dev.holdmytrack.android.map

import android.util.Log
import dev.holdmytrack.android.BuildConfig
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import org.maplibre.android.maps.Style
import org.maplibre.android.style.expressions.Expression
import org.maplibre.android.style.layers.BackgroundLayer
import org.maplibre.android.style.layers.CircleLayer
import org.maplibre.android.style.layers.FillLayer
import org.maplibre.android.style.layers.HeatmapLayer
import org.maplibre.android.style.layers.Layer
import org.maplibre.android.style.layers.LineLayer
import org.maplibre.android.style.layers.Property
import org.maplibre.android.style.layers.PropertyFactory
import org.maplibre.android.style.layers.PropertyValue
import org.maplibre.android.style.layers.SymbolLayer
import org.maplibre.android.style.sources.GeoJsonSource
import org.maplibre.android.style.sources.TileSet
import org.maplibre.android.style.sources.VectorSource
import org.maplibre.geojson.FeatureCollection
import java.util.WeakHashMap

/**
 * The layers document ([MapLayersDoc]) on a map: this adds what the document describes, applies
 * the mode's view, the Layers menu's switches and the app's vars, and decides nothing about how
 * anything looks. The web's `applyLayers.ts`.
 *
 * [state] is the app's, one for every map, so the export's hidden map
 * (`export/MapImageRenderer`) draws as the live one does. Each [Style] keeps the document applied
 * to it, and the tile URL each source was added with, by weak reference: a style reload replaces
 * the [Style], and its entry goes with it.
 */
object MapLayers {

    /** What the app decides, the rest being the document's. */
    data class State(
        val mode: MapMode = MapMode.NORMAL,
        /** Satellite imagery is drawn, which picks the views over it. */
        val satellite: Boolean = false,
        /** By [MapLayersDoc.Layer.toggle]: a layer whose switch isn't on is hidden. */
        val toggles: Map<String, Boolean> = emptyMap(),
        /** By var name, the value bound in place of the document's default. */
        val vars: Map<String, JsonElement> = emptyMap(),
        /** Groups the app steps aside, drawn hidden (a track being edited hides the tracks). */
        val hiddenGroups: Set<String> = emptySet(),
        /** By source id, the app's own query appended to its tiles (the tracks' range). */
        val queries: Map<String, String> = emptyMap(),
    )

    var state = State()
        private set

    private class Applied(val doc: MapLayersDoc.Doc, val excluded: Set<String>) {
        val urls = mutableMapOf<String, String>()
        val groups get() = doc.groups.filter { it.id !in excluded }
    }

    private val applied = WeakHashMap<Style, Applied>()

    /** The document on [style], or null before [attach]. */
    fun doc(style: Style): MapLayersDoc.Doc? = applied[style]?.doc

    /** The tier in view at [zoom], by [style]'s document. */
    fun tier(style: Style, zoom: Double): ZoomTier = MapLayersDoc.tier(applied[style]?.doc?.tiers.orEmpty(), zoom)

    /**
     * Adds [doc]'s sources and layers to [style], at their place in the stack, all but the groups
     * [excluded] (the export draws no Spots), and applies [state]. Re-runnable: a style reload
     * drops everything.
     */
    fun attach(style: Style, doc: MapLayersDoc.Doc, excluded: Set<String> = emptySet()) {
        val entry = applied[style]?.takeIf { it.doc === doc } ?: Applied(doc, excluded).also { applied[style] = it }
        add(style, entry)
        apply(style, entry)
    }

    /**
     * [doc] in place of the one on [style] — a new tile version. MapLibre Native can't change a
     * source's URL, so each vector source whose tiles changed is replaced with its layers, at the
     * same place in the stack, and the state put back.
     */
    fun replace(style: Style, doc: MapLayersDoc.Doc) {
        val old = applied[style] ?: return
        val next = Applied(doc, old.excluded)
        next.urls.putAll(old.urls)
        applied[style] = next
        resync(style, next)
    }

    /** [transform] applied to [state], and the result to [style] if it has a document: a new
     *  query is a new tile URL, which only a replaced source takes. */
    fun update(style: Style?, transform: (State) -> State) {
        state = transform(state)
        val entry = style?.let { applied[it] } ?: return
        resync(style, entry)
    }

    /** Replaces each vector source whose tile URL is no longer the one it was added with, and
     *  its layers, then adds whatever is missing and applies [state]. */
    private fun resync(style: Style, entry: Applied) {
        val stale = entry.groups.flatMap { group ->
            group.sources.filter { (id, source) -> source.tiles != null && entry.urls[id] != null && entry.urls[id] != url(source, id) }.keys
        }.toSet()
        for (group in entry.groups) for (layer in group.layers) {
            if (layer.source in stale) style.getLayer(layer.id)?.let(style::removeLayer)
        }
        stale.forEach { id ->
            style.removeSource(id)
            entry.urls.remove(id)
        }
        add(style, entry)
        apply(style, entry)
    }

    private fun url(source: MapLayersDoc.Source, id: String): String {
        val url = "${BuildConfig.API_BASE_URL}${source.tiles}"
        val query = state.queries[id].orEmpty()
        return if (query.isEmpty()) url else url + (if ('?' in url) "&" else "?") + query
    }

    private fun add(style: Style, entry: Applied) {
        val groups = entry.groups
        val own = groups.flatMap { group -> group.layers.map { it.id } }.toSet()
        val beneath = MapLayersDoc.order(groups, MapLayersDoc.Placement.BENEATH_LABELS)
        val top = MapLayersDoc.order(groups, MapLayersDoc.Placement.TOP)
        val labels = style.layers.firstOrNull { it is SymbolLayer && it.id !in own }?.id
        for (group in groups) {
            group.sources.forEach { (id, source) ->
                if (style.getSource(id) != null) return@forEach
                if (source.tiles == null) {
                    style.addSource(GeoJsonSource(id, FeatureCollection.fromFeatures(emptyList())))
                } else {
                    val url = url(source, id)
                    // "2.2.0" is the TileJSON version this describes, not the tile set's own version.
                    val tiles = TileSet("2.2.0", url).apply {
                        minZoom = source.minZoom
                        maxZoom = source.maxZoom
                        source.attribution?.let { attribution = it }
                    }
                    style.addSource(VectorSource(id, tiles))
                    entry.urls[id] = url
                }
            }
            val isTop = group.placement == MapLayersDoc.Placement.TOP
            for (id in group.lifts) lift(style, beneath, own, id, labels)
            for (spec in group.layers) {
                if (style.getLayer(spec.id) != null) continue
                val layer = layer(spec, entry.doc) ?: continue
                val before = beforeId(style, if (isTop) top else beneath, spec.id, own, if (isTop) null else labels)
                if (before != null) style.addLayerBelow(layer, before) else style.addLayer(layer)
            }
        }
    }

    private fun beforeId(style: Style, order: List<String>, id: String, own: Set<String>, fallback: String?): String? =
        MapLayersDoc.insertionPoint(style.layers.map { it.id }, order, id, own, fallback)

    /** Moves the basemap layer [id] up to its group if it's still below the document's own
     *  layers. MapLibre Native has no moveLayer: it's taken out and put back. */
    private fun lift(style: Style, beneath: List<String>, own: Set<String>, id: String, labels: String?) {
        if (!MapLayersDoc.needsLift(style.layers.map { it.id }, id, own)) return
        val layer = style.getLayer(id) ?: return
        val before = beforeId(style, beneath, id, own, labels)
        style.removeLayer(layer)
        if (before != null) style.addLayerBelow(layer, before) else style.addLayer(layer)
    }

    private fun apply(style: Style, entry: Applied) {
        val doc = entry.doc
        val view = MapLayersDoc.view(doc, state.mode, state.satellite)?.properties.orEmpty()
        val own = entry.groups.flatMap { group -> group.layers.map { it to group } }.associateBy { it.first.id }
        // The basemap's own layers a view sets: its labels, which Fog mutes.
        view.forEach { (id, props) ->
            if (id in own) return@forEach
            style.getLayer(id)?.setProperties(*props.mapNotNull { (k, v) -> property(k, v) }.toTypedArray())
        }
        for ((spec, group) in own.values) {
            val layer = style.getLayer(spec.id) ?: continue
            val props = view[spec.id].orEmpty()
            layer.setProperties(*props.filterKeys { it != "visibility" }.mapNotNull { (k, v) -> property(k, v) }.toTypedArray())
            // What a layer is added with holds until this first runs; from then the view, the
            // switch and the hidden groups decide.
            val base = ((props["visibility"] as? JsonPrimitive)?.content ?: Property.VISIBLE) == Property.VISIBLE
            val shown = base && (spec.toggle == null || state.toggles[spec.toggle] == true) && group.id !in state.hiddenGroups
            layer.setProperties(PropertyFactory.visibility(if (shown) Property.VISIBLE else Property.NONE))
            spec.vars.forEach { (name, names) ->
                if (name == "filter") {
                    spec.filter?.let { setFilter(layer, Expression.raw(MapLayersDoc.bind(it, names, state.vars, doc.vars).toString())) }
                } else {
                    spec.properties[name]?.let { value -> property(name, MapLayersDoc.bind(value, names, state.vars, doc.vars))?.let { layer.setProperties(it) } }
                }
            }
        }
    }

    /** Every property the document gives the layer of [role] on [style], for an overlay of the
     *  app's own to draw as it does (the Sync tab's candidates); none before [attach]. */
    fun propertiesOf(style: Style, role: String): Array<PropertyValue<*>> {
        val doc = applied[style]?.doc ?: return emptyArray()
        val spec = layerOf(doc, role) ?: return emptyArray()
        return spec.properties.filterKeys { it != "visibility" }
            .mapNotNull { (name, value) -> property(name, MapLayersDoc.bind(value, spec.vars[name].orEmpty(), state.vars, doc.vars)) }
            .toTypedArray()
    }

    /** The line color of the layer of [role] on [style] (the live recording takes the tracks'),
     *  from the document applied or, before that, the one kept on disk ([MapLayersSource]). */
    fun color(style: Style, role: String): String? {
        val doc = applied[style]?.doc ?: MapLayersSource.lastAny() ?: return null
        return (layerOf(doc, role)?.properties?.get("line-color") as? JsonPrimitive)?.takeIf { it.isString }?.content
    }

    private fun layerOf(doc: MapLayersDoc.Doc, role: String): MapLayersDoc.Layer? =
        doc.groups.firstNotNullOfOrNull { group -> group.layers.firstOrNull { it.role == role } }

    private fun layer(spec: MapLayersDoc.Layer, doc: MapLayersDoc.Doc): Layer? {
        val layer = when (spec.type) {
            "background" -> BackgroundLayer(spec.id)
            "fill" -> FillLayer(spec.id, spec.source).apply { spec.sourceLayer?.let(::setSourceLayer) }
            "line" -> LineLayer(spec.id, spec.source).apply { spec.sourceLayer?.let(::setSourceLayer) }
            "heatmap" -> HeatmapLayer(spec.id, spec.source).apply { spec.sourceLayer?.let(::setSourceLayer) }
            "circle" -> CircleLayer(spec.id, spec.source).apply { spec.sourceLayer?.let(::setSourceLayer) }
            "symbol" -> SymbolLayer(spec.id, spec.source).apply { spec.sourceLayer?.let(::setSourceLayer) }
            else -> {
                Log.w(TAG, "layer ${spec.id}: unsupported type ${spec.type}")
                return null
            }
        }
        spec.filter?.let { filter ->
            setFilter(layer, Expression.raw(MapLayersDoc.bind(filter, spec.vars["filter"].orEmpty(), state.vars, doc.vars).toString()))
        }
        spec.minZoom?.let(layer::setMinZoom)
        spec.maxZoom?.let(layer::setMaxZoom)
        val properties = spec.properties.mapNotNull { (name, value) ->
            property(name, MapLayersDoc.bind(value, spec.vars[name].orEmpty(), state.vars, doc.vars))
        }
        layer.setProperties(*properties.toTypedArray())
        return layer
    }

    private fun setFilter(layer: Layer, filter: Expression) {
        when (layer) {
            is FillLayer -> layer.setFilter(filter)
            is LineLayer -> layer.setFilter(filter)
            is HeatmapLayer -> layer.setFilter(filter)
            is CircleLayer -> layer.setFilter(filter)
            is SymbolLayer -> layer.setFilter(filter)
        }
    }

    private fun property(name: String, json: JsonElement): PropertyValue<*>? = when (val value = MapLayersDoc.value(json)) {
        is MapLayersDoc.Value.Expression -> PropertyValue(name, Expression.raw(value.json))
        is MapLayersDoc.Value.Literal -> PropertyValue(name, value.value)
        null -> null
    }

    private const val TAG = "MapLayers"
}
