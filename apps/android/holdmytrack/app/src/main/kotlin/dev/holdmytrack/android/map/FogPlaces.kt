package dev.holdmytrack.android.map

import android.view.View
import android.widget.TextView
import androidx.core.view.isVisible
import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonPrimitive as GsonPrimitive
import dev.holdmytrack.android.R
import kotlinx.serialization.json.JsonPrimitive
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.Style
import org.maplibre.android.style.layers.FillLayer
import java.text.NumberFormat

/**
 * In Fog, a tap on an outline on every level but Exact picks it: its border is drawn as the web
 * draws a hovered one (the layers document's picked layers, through its [VAR] var, since MapLibre
 * Native has no feature-state to set), and a popup over the tap names it ([FogPlaceLabel]): what
 * it is, where, whether it's explored, and of each level below it how many of its places are
 * (`docs/SPEC.md` FR-4.2). Its close button, a tap off every outline, a change of level or
 * leaving Fog closes it; it follows the map while open, as a spot's popup does.
 */
class FogPlaces(
    private val view: View,
    /** The chrome's bottom: the popup goes under the tap rather than up into it. */
    private val top: () -> Int,
) {
    private val res = view.resources
    private val name = view.findViewById<TextView>(R.id.fog_place_name)
    private val detail = view.findViewById<TextView>(R.id.fog_place_detail)
    private val state = view.findViewById<TextView>(R.id.fog_place_state)

    private var map: MapLibreMap? = null
    private var style: Style? = null
    private var at: LatLng? = null
    /** The level the picked outline is on: one coming into view in its place closes the popup. */
    private var level: String? = null

    init {
        view.findViewById<View>(R.id.fog_place_close).setOnClickListener { close() }
        view.addOnLayoutChangeListener { _, _, top, _, bottom, _, oldTop, _, oldBottom ->
            if (bottom - top != oldBottom - oldTop) place()
        }
    }

    /** Picks the outline under [point] on [style], or closes the popup when there's none to name.
     *  True when a place was picked. */
    fun tap(instance: MapLibreMap, style: Style, point: LatLng): Boolean {
        val levels = MapLayers.levels(style)
        val zoom = instance.cameraPosition.zoom
        val inView = FogLevels.inView(levels, zoom, MapLayers.state.fogLevel)
        val fills = levels.firstOrNull { it.level == inView && it.level != FogLevels.EXACT }
            ?.layers?.filter { style.getLayer(it) is FillLayer }.orEmpty()
        val feature = fills.takeIf { it.isNotEmpty() }?.let {
            instance.queryRenderedFeatures(instance.projection.toScreenLocation(point), *it.toTypedArray()).firstOrNull()
        }
        val props = feature?.properties()?.let(::properties)
        val label = props?.let { FogPlaceLabel.of(it, FogWords::has) }
        val id = (props?.get("id") as? Number)?.toLong()
        if (label == null || id == null) {
            close()
            return false
        }
        map = instance
        this.style = style
        at = point
        level = inView
        MapLayers.update(style) { it.copy(vars = it.vars + (VAR to JsonPrimitive(id))) }
        render(label)
        return true
    }

    fun close() {
        if (at == null) return
        at = null
        level = null
        view.isVisible = false
        MapLayers.update(style) { it.copy(vars = it.vars - VAR) }
    }

    /** Over the tap again on every camera move while open, and closed once the level changes. */
    fun onCameraMove() {
        val instance = map ?: return
        val picked = level ?: return
        val levels = style?.let(MapLayers::levels).orEmpty()
        if (FogLevels.inView(levels, instance.cameraPosition.zoom, MapLayers.state.fogLevel) != picked) return close()
        place()
    }

    private fun render(label: FogPlaceLabel.Label) {
        name.text = label.name
        detail.text = listOfNotNull(FogWords.string(label.kindKey)?.let(res::getString), label.within.takeIf { it.isNotEmpty() })
            .joinToString(" · ")
        val visited = FogWords.string(label.visitedKey)?.let(res::getString).orEmpty()
        // Explored, and of each level below, how many of its places in it are: 34 of 88 counties.
        val format = NumberFormat.getIntegerInstance()
        val counts = label.counts.mapNotNull { c ->
            FogWords.plural(c.key)?.let { res.getQuantityString(it, c.total, format.format(c.explored), format.format(c.total)) }
        }
        state.text = if (label.visitedKey == VISITED) (listOf(visited) + counts).joinToString(" · ") else visited
        view.isVisible = true
        place()
    }

    private fun place() {
        val instance = map ?: return
        val point = instance.projection.toScreenLocation(at ?: return)
        val density = res.displayMetrics.density
        val parent = view.parent as? View ?: return
        val gutter = GUTTER_DP * density
        val offset = OFFSET_DP * density
        val width = view.width
        view.translationX = (point.x - width / 2f).coerceIn(gutter, (parent.width - width - gutter).coerceAtLeast(gutter))
        val above = point.y - offset - view.height
        view.translationY = if (above >= top()) above else point.y + offset
    }

    /** A tile feature's properties as the label reads them: strings, numbers and booleans. */
    private fun properties(json: JsonObject): Map<String, Any?> = json.entrySet().associate { (key, value) -> key to primitive(value) }

    private fun primitive(value: JsonElement): Any? = (value as? GsonPrimitive)?.let {
        when {
            it.isBoolean -> it.asBoolean
            it.isNumber -> it.asNumber
            else -> it.asString
        }
    }

    private companion object {
        /** The layers document's var naming the picked outline by its tile `id`. */
        const val VAR = "fogPlace"
        const val VISITED = "map.fog.place.visited"
        const val GUTTER_DP = 8
        /** The web popup's 14px offset from the pointer. */
        const val OFFSET_DP = 14
    }
}