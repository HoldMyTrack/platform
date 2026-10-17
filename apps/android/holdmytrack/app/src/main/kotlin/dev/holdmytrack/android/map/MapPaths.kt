package dev.holdmytrack.android.map

import android.content.Context
import androidx.core.content.edit
import org.maplibre.android.maps.Style

/**
 * The Layers menu's Bike paths, Shared paths and Mountain bike trails (`docs/SPEC.md` FR-4.13,
 * [LayersMenu]), the layers document's `bike-paths` group: a per-device choice, each off until
 * turned on, kept in SharedPreferences like the theme (`settings/AppTheme.kt`), and applied as
 * the group's switches ([MapLayers]).
 */
object MapPaths {

    data class Paths(val bikePaths: Boolean, val sharedPaths: Boolean, val mtbTrails: Boolean) {
        /** How many are on: the Layers button's count. */
        val count: Int get() = listOf(bikePaths, sharedPaths, mtbTrails).count { it }
    }

    /** All hidden: what's drawn while Show layers is off ([MapLayersSwitch]). */
    val NONE = Paths(bikePaths = false, sharedPaths = false, mtbTrails = false)

    private const val PREFS = "map_paths"
    private const val KEY_BIKE_PATHS = "bike_paths"
    private const val KEY_SHARED_PATHS = "shared_paths"
    private const val KEY_MTB_TRAILS = "mtb_trails"

    /** The single Trails & bike paths toggle's key, from before the Layers menu: a phone that had
     *  it on starts with Bike paths on. */
    private const val KEY_LEGACY = "show"

    /** The Trails and Tracks entries' keys, from before trails and tracks were always drawn. */
    private val RETIRED_KEYS = listOf("trails", "tracks")

    fun get(context: Context): Paths {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return Paths(
            bikePaths = prefs.getBoolean(KEY_BIKE_PATHS, prefs.getBoolean(KEY_LEGACY, false)),
            sharedPaths = prefs.getBoolean(KEY_SHARED_PATHS, false),
            mtbTrails = prefs.getBoolean(KEY_MTB_TRAILS, false),
        )
    }

    fun set(context: Context, paths: Paths) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit {
            putBoolean(KEY_BIKE_PATHS, paths.bikePaths)
            putBoolean(KEY_SHARED_PATHS, paths.sharedPaths)
            putBoolean(KEY_MTB_TRAILS, paths.mtbTrails)
            remove(KEY_LEGACY)
            RETIRED_KEYS.forEach(::remove)
        }
    }

    /** [paths] as the layers document's switches, by its toggle names; kept for a style that
     *  attaches later. */
    fun apply(style: Style?, paths: Paths) {
        MapLayers.update(style) {
            it.copy(toggles = it.toggles + mapOf("bikePaths" to paths.bikePaths, "sharedPaths" to paths.sharedPaths, "mtbTrails" to paths.mtbTrails))
        }
    }
}
