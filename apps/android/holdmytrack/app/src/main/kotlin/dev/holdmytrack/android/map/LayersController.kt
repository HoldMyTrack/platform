package dev.holdmytrack.android.map

import android.content.res.Configuration
import android.view.View
import androidx.fragment.app.Fragment
import dev.holdmytrack.android.BuildConfig
import dev.holdmytrack.android.R
import org.maplibre.android.maps.Style

/**
 * What the map draws under and beside the user's history: the served style's flavor and
 * language, and the Layers menu's roads, paths, places and satellite imagery, each remembered on the
 * device. Show layers hides every pick at once and keeps them.
 */
class LayersController(
    private val fragment: Fragment,
    private val spots: SpotsController,
    /** The style once loaded, user layers or not. */
    private val style: () -> Style?,
    /** Whether the user layers are on it. */
    private val attached: () -> Boolean,
    private val mode: () -> MapMode,
) {
    private lateinit var menu: LayersMenu

    /** Whether the served style has satellite imagery; the Layers menu offers it only then. */
    private var satelliteAvailable = false

    private val context get() = fragment.requireContext()

    fun bind(root: View) {
        menu = LayersMenu(
            button = root.findViewById(R.id.layers_button),
            count = root.findViewById(R.id.layers_count),
            paths = { MapPaths.get(context) },
            spots = { MapSpots.get(context) },
            shown = { MapLayersSwitch.isOn(context) },
            onPaths = ::setPaths,
            onSpots = { categories -> spots.setPicked(categories, shownSpots(categories)) },
            onShown = ::setShown,
            satellite = { if (satelliteAvailable) MapSatellite.isOn(context) else null },
            onSatellite = ::setSatellite,
            roads = { MapRoads.isOn(context) },
            onRoads = ::setRoads,
            legend = { style()?.let(MapLayers::doc)?.group("bike-paths")?.legend.orEmpty() },
        )
    }

    fun dismiss() = menu.dismiss()

    /** The tour holds the menu open, view-only ([LayersMenu.hold]). */
    fun hold(open: Boolean) = menu.hold(open)

    val menuContent: View? get() = menu.content

    /** `light` or `dark`, following the app's night mode (`AppTheme`): the style's flavor, and
     *  the layers document's. */
    fun flavor(): String = if (isNight()) "dark" else "light"

    /** The style URL: [flavor], labels in the app's language (`?lang=`, root `docs/SPEC.md` FR-13.1). */
    fun styleUrl(): String {
        val lang = fragment.resources.configuration.locales[0].language
        return "${BuildConfig.API_BASE_URL}/v1/map/style/${flavor()}?lang=$lang"
    }

    fun isNight(): Boolean =
        fragment.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES

    /** Whether the basemap reads dark (dark flavor or satellite), which picks the export frame's colors. */
    fun darkBase(style: Style): Boolean = isNight() || satelliteDrawn(style)

    /** Satellite imagery is drawn on [style], which picks Fog's and Heatmap's view over it. */
    fun satelliteDrawn(style: Style): Boolean = MapSatellite.isOn(context) && MapSatellite.isAvailable(style)

    /** Satellite imagery is drawn: the deployment serves some and it's switched on. */
    val satelliteOn: Boolean get() = satelliteAvailable && MapSatellite.isOn(context)

    /** A style just loaded: it ships the path layers hidden, and only a deployment with imagery serves it. */
    fun onStyleLoaded(loaded: Style) {
        applyPaths(loaded)
        satelliteAvailable = MapSatellite.isAvailable(loaded)
        MapSatellite.apply(loaded, MapSatellite.isOn(context))
        applyRoads(loaded)
    }

    /** Satellite and the roads onto the export's map. */
    fun applyBasemap(loaded: Style) {
        MapSatellite.apply(loaded, satelliteOn)
        applyRoads(loaded)
    }

    /** The roads drawn: picked, while Show layers is on. */
    private fun applyRoads(loaded: Style) = MapRoads.apply(loaded, MapLayersSwitch.isOn(context) && MapRoads.isOn(context))

    /** The path picks onto [loaded], all hidden while Show layers is off. */
    fun applyPaths(loaded: Style) = MapPaths.apply(loaded, shownPaths(MapPaths.get(context)))

    /** The place picks drawn: all while Show layers is on, none while off. */
    fun shownSpots(categories: List<MapSpots.Category> = MapSpots.get(context)): List<MapSpots.Category> =
        if (MapLayersSwitch.isOn(context)) categories else emptyList()

    private fun shownPaths(paths: MapPaths.Paths) = if (MapLayersSwitch.isOn(context)) paths else MapPaths.NONE

    private fun setPaths(paths: MapPaths.Paths) {
        MapPaths.set(context, paths)
        style()?.let { MapPaths.apply(it, shownPaths(paths)) }
    }

    /** Show layers: shows or hides every pick, keeping them. A capture in progress carries on. */
    private fun setShown(on: Boolean) {
        MapLayersSwitch.set(context, on)
        style()?.let {
            applyPaths(it)
            applyRoads(it)
        }
        spots.show(shownSpots())
    }

    private fun setSatellite(on: Boolean) {
        MapSatellite.set(context, on)
        val loaded = style() ?: return
        MapSatellite.apply(loaded, on)
        if (attached()) MapLayers.update(loaded) { it.copy(satellite = satelliteDrawn(loaded)) }
    }

    private fun setRoads(on: Boolean) {
        MapRoads.set(context, on)
        style()?.let(::applyRoads)
    }
}
