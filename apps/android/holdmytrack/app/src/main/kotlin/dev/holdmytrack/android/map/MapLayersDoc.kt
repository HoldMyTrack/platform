package dev.holdmytrack.android.map

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * The layers document, `GET /v1/map/layers` (root `docs/ARCHITECTURE.md` §2.1, ADR-0048): every
 * layer HoldMyTrack draws over the basemap, what each mode shows and how, and the zoom tiers,
 * defined once in the web's `apps/web/src/map/mapLayers.ts`. This reads it; [MapLayers] puts it
 * on a map. Pure, so nothing here needs MapLibre.
 */
object MapLayersDoc {

    /** The metadata keys the document's runtime hooks travel as. */
    const val TOGGLE_METADATA = "holdmytrack:toggle"
    const val VARS_METADATA = "holdmytrack:vars"
    const val ROLE_METADATA = "holdmytrack:role"

    enum class Placement { BENEATH_LABELS, TOP }

    /** A `vector` source of the account's tiles, or a `geojson` one the app fills ([tiles] null). */
    data class Source(val tiles: String?, val minZoom: Float, val maxZoom: Float, val attribution: String?)

    /** One layer: its MapLibre type, where it draws from, every property it's added with, and its hooks. */
    data class Layer(
        val id: String,
        val type: String,
        val source: String?,
        val sourceLayer: String?,
        val minZoom: Float?,
        val maxZoom: Float?,
        val filter: JsonElement?,
        val properties: Map<String, JsonElement>,
        /** The Layers menu switch that shows it, or null for none. */
        val toggle: String?,
        /** By property name, or `filter`, the vars it reads. */
        val vars: Map<String, List<String>>,
        val role: String?,
    ) {
        /** Drawn hidden until a view or a switch shows it. */
        val hidden: Boolean get() = (properties["visibility"] as? JsonPrimitive)?.content == "none"
    }

    /** A Layers menu legend line; [dash] in line widths, null for a solid line. */
    data class Legend(val color: String, val dash: FloatArray?)

    data class Group(
        val id: String,
        val placement: Placement,
        val lifts: List<String>,
        val sources: Map<String, Source>,
        val layers: List<Layer>,
        val legend: Map<String, Legend>,
    )

    /** A view: by layer id, the properties to set, layout and paint alike (their names don't overlap). */
    data class View(val properties: Map<String, Map<String, JsonElement>>)

    data class Tier(val tier: ZoomTier, val below: Double?)

    data class Doc(
        val styleBuild: String,
        val flavor: String,
        val tileVersion: String,
        val tiers: List<Tier>,
        /** By name, the default of each value a layer reads as `["var", name]`. */
        val vars: Map<String, JsonElement>,
        val plain: Map<MapMode, View>,
        val satellite: Map<MapMode, View>,
        val groups: List<Group>,
    ) {
        fun group(id: String): Group? = groups.firstOrNull { it.id == id }
    }

    /** A property's value as MapLibre Native takes it: an expression, as its JSON, or a literal. */
    sealed interface Value {
        data class Expression(val json: String) : Value
        data class Literal(val value: Any) : Value
    }

    /** [text] as a document, or null for one that doesn't parse. */
    fun parse(text: String): Doc? = runCatching { doc(Json.parseToJsonElement(text).jsonObject) }.getOrNull()

    /** The view for [mode], over satellite imagery or not. */
    fun view(doc: Doc, mode: MapMode, satellite: Boolean): View? = (if (satellite) doc.satellite else doc.plain)[mode]

    /** The tier in view at [zoom]: the first whose `below` is past it. */
    fun tier(tiers: List<Tier>, zoom: Double): ZoomTier =
        tiers.firstOrNull { it.below == null || zoom < it.below }?.tier ?: ZoomTier.CITY

    /** Every array is an expression (the document's contract); numbers are floats, which is what
     *  MapLibre Native's number properties take. */
    fun value(json: JsonElement): Value? = when {
        json is JsonArray -> Value.Expression(json.toString())
        json is JsonPrimitive && json.isString -> Value.Literal(json.content)
        json is JsonPrimitive -> json.booleanOrNull?.let { Value.Literal(it) }
            ?: json.doubleOrNull?.let { Value.Literal(it.toFloat()) }
        else -> null
    }

    /** [value] with each of [names] bound to the app's [vars], or the document's [defaults], as a
     *  `let` expression around it. An array is bound as a literal. */
    fun bind(value: JsonElement, names: List<String>, vars: Map<String, JsonElement>, defaults: Map<String, JsonElement>): JsonElement {
        if (names.isEmpty()) return value
        val bindings = names.flatMap { name ->
            val bound = vars[name] ?: defaults[name] ?: JsonNull
            listOf(JsonPrimitive(name), if (bound is JsonArray) JsonArray(listOf(JsonPrimitive("literal"), bound)) else bound)
        }
        return JsonArray(listOf(JsonPrimitive("let")) + bindings + value)
    }

    /** Each layer id of [placement] in paint order, the basemap layers groups lift included. */
    fun order(groups: List<Group>, placement: Placement): List<String> =
        groups.filter { it.placement == placement }.flatMap { it.lifts + it.layers.map(Layer::id) }

    /**
     * Where layer [id] goes in, or a lifted basemap layer moves to, among the map's [current]
     * layers (bottom to top): under the next one after it in [order] that's already in place, else
     * under [fallback]. A basemap layer to lift is in place only once it's above the lowest of [own].
     */
    fun insertionPoint(current: List<String>, order: List<String>, id: String, own: Set<String>, fallback: String?): String? {
        val lowest = current.indexOfFirst { it in own }
        return order.drop(order.indexOf(id) + 1).firstOrNull { next ->
            val at = current.indexOf(next)
            at >= 0 && (next in own || (lowest >= 0 && at > lowest))
        } ?: fallback
    }

    /** Whether basemap layer [id] still sits below the lowest of [own], so has to be lifted. */
    fun needsLift(current: List<String>, id: String, own: Set<String>): Boolean {
        val at = current.indexOf(id)
        val lowest = current.indexOfFirst { it in own }
        return at >= 0 && !(lowest in 0 until at)
    }

    private fun doc(o: JsonObject): Doc {
        val views = o.obj("views")
        return Doc(
            styleBuild = o.string("styleBuild").orEmpty(),
            flavor = o.string("flavor").orEmpty(),
            tileVersion = o.string("tileVersion").orEmpty(),
            tiers = (o["tiers"] as JsonArray).map { t ->
                val tier = t.jsonObject
                Tier(ZoomTier.valueOf(tier.string("tier")!!.uppercase()), tier["below"]?.jsonPrimitive?.doubleOrNull)
            },
            vars = o["vars"]?.jsonObject.orEmpty(),
            plain = views(views.obj("plain")),
            satellite = views(views.obj("satellite")),
            groups = (o["groups"] as JsonArray).map { group(it.jsonObject) },
        )
    }

    private fun group(g: JsonObject) = Group(
        id = g.string("id")!!,
        placement = if (g.string("placement") == "top") Placement.TOP else Placement.BENEATH_LABELS,
        lifts = (g["lifts"] as? JsonArray)?.map { it.jsonPrimitive.content }.orEmpty(),
        sources = g.obj("sources").mapValues { (_, s) ->
            val source = s.jsonObject
            Source(
                tiles = source.string("tiles"),
                minZoom = source.float("minzoom") ?: 0f,
                maxZoom = source.float("maxzoom") ?: 22f,
                attribution = source.string("attribution"),
            )
        },
        layers = (g["layers"] as JsonArray).map { layer(it.jsonObject) },
        legend = (g["legend"] as? JsonObject)?.mapValues { (_, l) ->
            val entry = l.jsonObject
            Legend(entry.string("color")!!, (entry["dash"] as? JsonArray)?.map { it.jsonPrimitive.doubleOrNull!!.toFloat() }?.toFloatArray())
        }.orEmpty(),
    )

    private fun layer(l: JsonObject): Layer {
        val metadata = l["metadata"] as? JsonObject
        return Layer(
            id = l.string("id")!!,
            type = l.string("type")!!,
            source = l.string("source"),
            sourceLayer = l.string("source-layer"),
            minZoom = l.float("minzoom"),
            maxZoom = l.float("maxzoom"),
            filter = l["filter"],
            properties = (l["layout"] as? JsonObject).orEmpty() + (l["paint"] as? JsonObject).orEmpty(),
            toggle = metadata?.string(TOGGLE_METADATA),
            vars = (metadata?.get(VARS_METADATA) as? JsonObject)?.mapValues { (_, names) -> names.jsonArray.map { it.jsonPrimitive.content } }.orEmpty(),
            role = metadata?.string(ROLE_METADATA),
        )
    }

    private fun views(modes: JsonObject): Map<MapMode, View> = MapMode.entries.mapNotNull { mode ->
        val view = modes[mode.name.lowercase()]?.jsonObject ?: return@mapNotNull null
        val byLayer = mutableMapOf<String, Map<String, JsonElement>>()
        for (kind in listOf("layout", "paint")) {
            view[kind]?.jsonObject?.forEach { (id, props) -> byLayer[id] = byLayer[id].orEmpty() + props.jsonObject }
        }
        mode to View(byLayer)
    }.toMap()

    private fun JsonObject.obj(key: String): JsonObject = this[key]!!.jsonObject
    private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
    private fun JsonObject.float(key: String): Float? = (this[key] as? JsonPrimitive)?.doubleOrNull?.toFloat()
}
