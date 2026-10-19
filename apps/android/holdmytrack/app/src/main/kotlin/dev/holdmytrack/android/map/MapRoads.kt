package dev.holdmytrack.android.map

import android.content.Context
import androidx.core.content.edit
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import org.maplibre.android.maps.Style
import org.maplibre.android.style.layers.Property
import org.maplibre.android.style.layers.PropertyFactory

/**
 * Roads, a pick in the Layers menu (`docs/SPEC.md` FR-4.17): shows or hides the layers the served
 * style lists under `holdmytrack:roads` (apps/web/src/map/style.ts's `ROADS_METADATA`), drawn
 * while picked and Show layers ([MapLayersSwitch]) is on. A per-device choice, on until unpicked,
 * kept in SharedPreferences like [MapPaths].
 */
object MapRoads {

    private const val ROADS_METADATA = "holdmytrack:roads"

    private const val PREFS = "map_roads"
    private const val KEY = "show"

    fun isOn(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY, true)

    fun set(context: Context, on: Boolean) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit { putBoolean(KEY, on) }
    }

    fun apply(style: Style, shown: Boolean) {
        val visibility = PropertyFactory.visibility(if (shown) Property.VISIBLE else Property.NONE)
        (StyleMetadata.of(style)[ROADS_METADATA] as? JsonArray)
            ?.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }
            ?.forEach { id -> style.getLayer(id)?.setProperties(visibility) }
    }
}