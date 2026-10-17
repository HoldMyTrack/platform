package dev.holdmytrack.android.map

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PointF
import android.graphics.RectF
import androidx.annotation.DrawableRes
import androidx.annotation.StringRes
import androidx.appcompat.content.res.AppCompatResources
import androidx.core.content.edit
import androidx.core.graphics.createBitmap
import androidx.core.graphics.toColorInt
import dev.holdmytrack.android.R
import dev.holdmytrack.android.net.Spot
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.Style
import org.maplibre.android.style.layers.LineLayer
import org.maplibre.android.style.layers.Property
import org.maplibre.android.style.layers.PropertyFactory
import org.maplibre.android.style.sources.GeoJsonSource
import org.maplibre.geojson.Feature
import org.maplibre.geojson.FeatureCollection
import org.maplibre.geojson.LineString
import org.maplibre.geojson.Point
import java.time.Instant

/**
 * The Spots layers (`docs/SPEC.md` FR-15, root `docs/IMPLEMENTATION.md` §4.25) as the layers
 * document's `spots` group draws them ([MapLayers]), and what the app decides about them: the
 * categories the Layers menu has on ([LayersMenu]), the account's captures, capture mode's target
 * and guide, and "Show in this area"'s places ([ShowInArea]). The web's `map/spots.ts`.
 *
 * The choice is per device, every category off until ticked, kept in SharedPreferences like
 * [MapPaths].
 */
object MapSpots {

    /** The categories, in the order the Layers menu lists them (the web's `SPOT_CATEGORIES`). */
    enum class Category(
        val wire: String,
        @param:DrawableRes val icon: Int,
        @param:StringRes val menuLabel: Int,
        @param:StringRes val label: Int,
    ) {
        PLAYGROUND("playground", R.drawable.ic_seesaw, R.string.layers_playgrounds, R.string.spots_category_playground),
        DOG_PARK("dog_park", R.drawable.ic_dog, R.string.layers_dog_parks, R.string.spots_category_dog_park),
        MONUMENT("monument", R.drawable.ic_landmark, R.string.layers_monuments, R.string.spots_category_monument),
        VIEWPOINT("viewpoint", R.drawable.ic_binoculars, R.string.layers_viewpoints, R.string.spots_category_viewpoint),
        HISTORY("history", R.drawable.ic_castle, R.string.layers_history, R.string.spots_category_history),
        ;

        companion object {
            fun fromWire(wire: String): Category? = entries.firstOrNull { it.wire == wire }
        }
    }

    private const val IN_AREA_SOURCE_ID = "spots-in-area"
    private const val IN_AREA_LAYER_ID = "spots-in-area-icons"
    private const val LAYER_ID = "spots-icons"
    private const val GUIDE_SOURCE_ID = "spots-capture-guide"
    private const val GUIDE_LAYER_ID = "spots-capture-guide"

    /** The badge layers — what a tap can hit. */
    private val BADGE_LAYER_IDS = setOf(IN_AREA_LAYER_ID, LAYER_ID)

    private const val BADGE_DP = 30f

    /** How far from a badge's edge a tap still counts. */
    private const val TAP_SLOP_DP = 4f

    private const val PREFS = "map_spots"
    private const val KEY = "categories"

    private var wanted: List<Category> = emptyList()
    private var editing = false
    private var inArea: FeatureCollection = FeatureCollection.fromFeatures(emptyList())

    /** The places the account has captured (`docs/SPEC.md` FR-15.6), by id: drawn with the
     *  captured badge, and dated in their popup. */
    var captured: Map<Long, Instant> = emptyMap()
        private set

    /** The place capture mode is aiming at, or null with it off. */
    private var target: Long? = null

    /** Capture mode's dashed line, from the user to the nearest point of the target's area. */
    private var guide: FeatureCollection = FeatureCollection.fromFeatures(emptyList())

    /** The zooms "Show in this area" offers places between, its layer's in the layers document:
     *  from a metro area in view to the tiles' first. Null before the document is on [style]. */
    fun inAreaZooms(style: Style): ClosedFloatingPointRange<Double>? {
        val layer = MapLayers.doc(style)?.group("spots")?.layers?.firstOrNull { it.id == IN_AREA_LAYER_ID } ?: return null
        return (layer.minZoom ?: return null).toDouble()..(layer.maxZoom ?: return null).toDouble()
    }

    fun get(context: Context): List<Category> {
        val saved = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getStringSet(KEY, emptySet()).orEmpty()
        return Category.entries.filter { it.wire in saved }
    }

    fun set(context: Context, categories: List<Category>) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit {
            putStringSet(KEY, categories.map { it.wire }.toSet())
        }
    }

    /**
     * Draws the badge images the layers document names, puts "Show in this area"'s places back,
     * adds capture mode's guide and shows [categories]. Re-runnable: a style reload (a day/night
     * swap) drops all of them.
     */
    fun attach(style: Style, context: Context, categories: List<Category>) {
        wanted = categories
        addImages(style, context)
        style.getSourceAs<GeoJsonSource>(IN_AREA_SOURCE_ID)?.setGeoJson(inArea)
        if (style.getSource(GUIDE_SOURCE_ID) == null) style.addSource(GeoJsonSource(GUIDE_SOURCE_ID, guide))
        if (style.getLayer(GUIDE_LAYER_ID) == null) {
            // Under the badges, over the areas, in the areas' color: the app's own drawing.
            val guideLayer = LineLayer(GUIDE_LAYER_ID, GUIDE_SOURCE_ID).withProperties(
                PropertyFactory.lineWidth(2.5f),
                PropertyFactory.lineDasharray(arrayOf(1.5f, 1.5f)),
                PropertyFactory.lineCap(Property.LINE_CAP_ROUND),
            )
            MapLayers.color(style, "spot-area")?.let { guideLayer.setProperties(PropertyFactory.lineColor(it)) }
            if (style.getLayer(IN_AREA_LAYER_ID) != null) style.addLayerBelow(guideLayer, IN_AREA_LAYER_ID) else style.addLayer(guideLayer)
        }
        apply(style)
    }

    /** Shows [categories] and hides the rest. */
    fun setCategories(style: Style, categories: List<Category>) {
        wanted = categories
        apply(style)
    }

    /** The account's captures, newest from `GET /v1/spots/captures` or one just made. */
    fun setCaptured(style: Style?, captures: Map<Long, Instant>) {
        captured = captures
        style?.let(::apply)
    }

    /**
     * Capture mode (`apps/android/docs/SPEC.md` FR-2.8) on [targetId], or off with null: every
     * area shaded darker, the target's darkest and its edge thicker, so the places stand out
     * from the map while the user is looking for one.
     */
    fun setCapturing(style: Style?, targetId: Long?) {
        target = targetId
        if (targetId == null) guide = FeatureCollection.fromFeatures(emptyList())
        style?.let {
            it.getSourceAs<GeoJsonSource>(GUIDE_SOURCE_ID)?.setGeoJson(guide)
            apply(it)
        }
    }

    /** Capture mode's guide line, from [from] to [to]; null clears it (the user is inside). */
    fun setGuide(style: Style?, from: GeoPoint?, to: GeoPoint?) {
        guide = FeatureCollection.fromFeatures(
            if (from == null || to == null) emptyList()
            else listOf(Feature.fromGeometry(LineString.fromLngLats(listOf(Point.fromLngLat(from.lon, from.lat), Point.fromLngLat(to.lon, to.lat))))),
        )
        style?.getSourceAs<GeoJsonSource>(GUIDE_SOURCE_ID)?.setGeoJson(guide)
    }

    /** A track is being edited: the places step aside with every other track, as on the web
     *  (`docs/SPEC.md` FR-15.2). */
    fun setEditing(style: Style, next: Boolean) {
        editing = next
        apply(style)
    }

    /** Draws "Show in this area"'s places, replacing the last ones; null clears. Kept here too,
     *  so a style reload puts them back. */
    fun setInArea(style: Style?, spots: List<Spot>?) {
        inArea = FeatureCollection.fromFeatures(
            spots.orEmpty().map { spot ->
                Feature.fromGeometry(Point.fromLngLat(spot.lon, spot.lat)).apply {
                    addNumberProperty("id", spot.id)
                    addStringProperty("category", spot.category)
                    addNumberProperty("lon", spot.lon)
                    addNumberProperty("lat", spot.lat)
                    spot.name?.let { addStringProperty("name", it) }
                    spot.address?.let { addStringProperty("address", it) }
                    spot.description?.let { addStringProperty("description", it) }
                    spot.inscription?.let { addStringProperty("inscription", it) }
                    spot.memorial?.let { addStringProperty("memorial", it) }
                    spot.startDate?.let { addStringProperty("start_date", it) }
                    spot.wikipedia?.let { addStringProperty("wikipedia", it) }
                }
            },
        )
        style?.getSourceAs<GeoJsonSource>(IN_AREA_SOURCE_ID)?.setGeoJson(inArea)
    }

    /** The showing spot at a screen point, if any — from the tiles or from "Show in this
     *  area". Asked before the tracks, so a tap on a spot doesn't also select a track. */
    fun spotAt(map: MapLibreMap, screen: PointF, density: Float): Spot? {
        val style = map.style ?: return null
        val layers = BADGE_LAYER_IDS.filter { id -> style.getLayer(id)?.visibility?.value == Property.VISIBLE }
        if (layers.isEmpty()) return null
        val slop = TAP_SLOP_DP * density
        val box = RectF(screen.x - slop, screen.y - slop, screen.x + slop, screen.y + slop)
        return map.queryRenderedFeatures(box, *layers.toTypedArray()).firstOrNull()?.let(::toSpot)
    }

    private fun toSpot(feature: Feature): Spot {
        fun text(key: String) = feature.getStringProperty(key)?.takeIf { it.isNotEmpty() }
        fun number(key: String) = if (feature.hasNonNullValueForProperty(key)) feature.getNumberProperty(key) else null
        return Spot(
            id = number("id")?.toLong() ?: 0L,
            category = feature.getStringProperty("category").orEmpty(),
            name = text("name"),
            address = text("address"),
            description = text("description"),
            inscription = text("inscription"),
            memorial = text("memorial"),
            startDate = text("start_date"),
            wikipedia = text("wikipedia"),
            lon = number("lon")?.toDouble() ?: 0.0,
            lat = number("lat")?.toDouble() ?: 0.0,
        )
    }

    /**
     * The categories shown, the captures and capture mode's target, as the layers document's
     * `spots` switch and vars: every layer hidden with none wanted or a track being edited. The
     * document decides what each does: retired places, captured badges, the darker areas.
     */
    private fun apply(style: Style) {
        val shown = wanted.isNotEmpty() && !editing
        MapLayers.update(style) {
            it.copy(
                toggles = it.toggles + ("spots" to shown),
                vars = it.vars + mapOf(
                    "spotCategories" to JsonArray(wanted.map { category -> JsonPrimitive(category.wire) }),
                    "captured" to JsonArray(captured.keys.sorted().map(::JsonPrimitive)),
                    "captureTarget" to JsonPrimitive(target ?: -1L),
                ),
            )
        }
        style.getLayer(GUIDE_LAYER_ID)?.setProperties(PropertyFactory.visibility(if (shown && target != null) Property.VISIBLE else Property.NONE))
    }

    /** Every badge the layers document names, drawn once per style load in its colors: a style
     *  reload drops its images with its layers. The icon shapes are the app's. */
    private fun addImages(style: Style, context: Context) {
        val badges = MapLayers.doc(style)?.group("spots")?.layers?.flatMap { it.images.entries }?.associate { it.key to it.value }.orEmpty()
        val metrics = context.resources.displayMetrics
        val size = (BADGE_DP * metrics.density).toInt()
        val unit = size / BADGE_DP
        for ((name, badge) in badges) {
            if (style.getImage(name) != null) continue
            val category = Category.fromWire(badge.category) ?: continue
            val bitmap = createBitmap(size, size).apply { density = metrics.densityDpi }
            val canvas = Canvas(bitmap)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG)
            paint.style = Paint.Style.FILL
            paint.color = badge.fill.toColorInt()
            canvas.drawCircle(size / 2f, size / 2f, 13.5f * unit, paint)
            paint.style = Paint.Style.STROKE
            paint.strokeWidth = 2f * unit
            paint.color = badge.ring.toColorInt()
            canvas.drawCircle(size / 2f, size / 2f, 13.5f * unit, paint)
            // Lucide draws in a 24-unit box; 16 of the badge's 30 units leaves a comfortable margin.
            val icon = AppCompatResources.getDrawable(context, category.icon)!!.mutate()
            icon.setTint(badge.ink.toColorInt())
            icon.setBounds((7 * unit).toInt(), (7 * unit).toInt(), (23 * unit).toInt(), (23 * unit).toInt())
            icon.draw(canvas)
            style.addImage(name, bitmap)
        }
    }
}
