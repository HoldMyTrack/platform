package dev.holdmytrack.android.map

import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Reads the layers document the server serves, as built from the web's `mapLayers.ts`. */
class MapLayersDocTest {

    private fun served(name: String): String {
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        val path = "services/server/internal/mapstyle/$name"
        while (dir != null && !File(dir, path).isFile) dir = dir.parentFile
        return File(dir ?: error("$path not found above ${System.getProperty("user.dir")}"), path).readText()
    }

    private val light = MapLayersDoc.parse(served("layers/light.json")) ?: error("layers/light.json doesn't parse")

    private val coverage = light.group("coverage")!!

    @Test
    fun theDocumentAndTheStyleComeFromOneBuild() {
        assertTrue(light.styleBuild.isNotEmpty())
        assertEquals(light.styleBuild, StyleMetadata.parse(served("styles/en/light.json"))[StyleMetadata.STYLE_BUILD]?.let { (it as JsonPrimitive).content })
        assertEquals("light", light.flavor)
    }

    @Test
    fun everyLayerDrawsFromASourceItsGroupCarries() {
        for (group in light.groups) for (layer in group.layers) {
            layer.source?.let { assertNotNull(layer.id, group.sources[it]) }
        }
        val fog = coverage.sources.getValue("fog-vector")
        assertEquals("/tiles/v1/fog-vector/{z}/{x}/{y}.mvt?cv=__HOLDMYTRACK_TILE_VERSION__", fog.tiles)
        assertEquals(14f, fog.maxZoom)
    }

    @Test
    fun everyModeHasAViewOverImageryOrNot() {
        for (satellite in listOf(false, true)) {
            for (mode in MapMode.entries) assertNotNull(MapLayersDoc.view(light, mode, satellite))
        }
    }

    @Test
    fun fogShowsTheVeilAndMutesLabels() {
        val fog = MapLayersDoc.view(light, MapMode.FOG, false)!!.properties
        val normal = MapLayersDoc.view(light, MapMode.NORMAL, false)!!.properties
        assertEquals(JsonPrimitive("visible"), fog.getValue("fog-veil").getValue("visibility"))
        assertEquals(JsonPrimitive("none"), normal.getValue("fog-veil").getValue("visibility"))
        val label = fog.keys.first { it.startsWith("places_") }
        assertEquals(0.4, (fog.getValue(label).getValue("text-opacity") as JsonPrimitive).content.toDouble(), 1e-9)
        assertEquals(1.0, (normal.getValue(label).getValue("text-opacity") as JsonPrimitive).content.toDouble(), 1e-9)
    }

    @Test
    fun imageryTakesTheDarkVeil() {
        fun veil(satellite: Boolean) = MapLayersDoc.view(light, MapMode.FOG, satellite)!!.properties.getValue("fog-veil").getValue("fill-color")
        assertEquals(JsonPrimitive("#202b25"), veil(false))
        assertEquals(JsonPrimitive("#f7f4ec"), veil(true))
    }

    @Test
    fun layersCarryExpressionsAsJson() {
        val heat = coverage.layers.first { it.id == "heat-points-circles" }
        assertEquals("heatmap", heat.type)
        assertEquals("heat", heat.sourceLayer)
        assertTrue(MapLayersDoc.value(heat.properties.getValue("heatmap-radius")) is MapLayersDoc.Value.Expression)
        assertEquals(MapLayersDoc.Value.Literal(2.5f), MapLayersDoc.value(heat.properties.getValue("heatmap-intensity")))
        val veil = coverage.layers.first { it.id == "fog-veil" }
        assertEquals("""["==",["get","kind"],"veil"]""", veil.filter.toString())
        assertTrue(veil.hidden)
    }

    @Test
    fun groupsGoInPaintOrderByPlacement() {
        val beneath = MapLayersDoc.order(light.groups, MapLayersDoc.Placement.BENEATH_LABELS)
        assertEquals(coverage.layers.first().id, beneath.first())
        assertEquals(beneath.size, beneath.toSet().size)
    }

    @Test
    fun theBikePathsLiftTheTrailsEachBehindItsSwitch() {
        val bike = light.group("bike-paths")!!
        assertEquals(listOf("paths_trail", "paths_track", "paths_bridges_trail", "paths_bridges_track"), bike.lifts)
        assertEquals(listOf("mtbTrails", "sharedPaths", "bikePaths"), bike.layers.map { it.toggle })
        assertTrue(bike.layers.all { it.hidden })
        assertEquals("#0b5a85", bike.legend.getValue("bikePaths").color)
        assertTrue(floatArrayOf(2f, 1f).contentEquals(bike.legend.getValue("trails").dash))
        assertNull(bike.legend.getValue("bikePaths").dash)
        val beneath = MapLayersDoc.order(light.groups, MapLayersDoc.Placement.BENEATH_LABELS)
        assertTrue(beneath.indexOf("paths_trail") > beneath.indexOf("heat-points-circles"))
    }

    @Test
    fun theTracksFilterByTheIdSetsTheAppBinds() {
        val tracks = light.group("tracks")!!
        assertEquals(listOf("tracks-casing", MapOverlays.TRACKS_LAYER_ID, "tracks-focused", "tracks-hover"), tracks.layers.map { it.id })
        assertEquals(listOf("casing", "track", "focused", null), tracks.layers.map { it.role })
        assertEquals(listOf("focused", "hidden"), tracks.layers.first { it.id == "tracks-focused" }.vars.getValue("filter"))
        assertTrue(light.vars.keys.containsAll(setOf("hidden", "focused", "hovered")))
        assertEquals(MapOverlays.BAND_LAYER_ID, light.group("track-bands")!!.layers.single().id)
        assertEquals(MapOverlays.TRACKS_MIN_ZOOM, tracks.layers.first().minZoom)
        val beneath = MapLayersDoc.order(light.groups, MapLayersDoc.Placement.BENEATH_LABELS)
        assertTrue(beneath.indexOf(MapOverlays.TRACKS_LAYER_ID) < beneath.indexOf(MapOverlays.BAND_LAYER_ID))
    }

    @Test
    fun theSpotsGoOnTopWithTheBadgesToDraw() {
        val spots = light.group("spots")!!
        assertEquals(MapLayersDoc.Placement.TOP, spots.placement)
        assertTrue(spots.layers.all { it.toggle == "spots" })
        val icons = spots.layers.first { it.id == "spots-icons" }
        assertEquals("symbol", icons.type)
        assertEquals(MapLayersDoc.Badge("playground", "#b07e2e", "#7d5820", "#ffffff"), icons.images.getValue("spot-playground-captured"))
        assertEquals(10, icons.images.size)
        assertTrue(MapSpots.Category.entries.all { "spot-${it.wire}" in icons.images })
        assertNull(spots.sources.getValue("spots-in-area").tiles)
        assertEquals(JsonPrimitive(-1), light.vars["captureTarget"])
        val inArea = spots.layers.first { it.id == "spots-in-area-icons" }
        assertEquals(10f, inArea.minZoom)
        assertEquals(13f, inArea.maxZoom)
    }

    @Test
    fun tiersSwitchWhereTheFillsHandOver() {
        assertEquals(ZoomTier.COUNTRY, MapLayersDoc.tier(light.tiers, 2.99))
        assertEquals(ZoomTier.REGION, MapLayersDoc.tier(light.tiers, 3.0))
        assertEquals(ZoomTier.REGION, MapLayersDoc.tier(light.tiers, 6.99))
        assertEquals(ZoomTier.CITY, MapLayersDoc.tier(light.tiers, 7.0))
        assertEquals(ZoomTier.CITY, MapLayersDoc.tier(emptyList(), 1.0))
    }

    @Test
    fun valuesAreExpressionsOrLiterals() {
        assertEquals(MapLayersDoc.Value.Expression("""["get","w"]"""), MapLayersDoc.value(JsonArray(listOf(JsonPrimitive("get"), JsonPrimitive("w")))))
        assertEquals(MapLayersDoc.Value.Literal(0.82f), MapLayersDoc.value(JsonPrimitive(0.82)))
        assertEquals(MapLayersDoc.Value.Literal(true), MapLayersDoc.value(JsonPrimitive(true)))
        assertEquals(MapLayersDoc.Value.Literal("butt"), MapLayersDoc.value(JsonPrimitive("butt")))
    }

    @Test
    fun varsBindWithLetTheAppsValueOverTheDefault() {
        val filter = Json.parseToJsonElement("""["in",["get","id"],["var","hidden"]]""")
        val defaults = mapOf("hidden" to JsonArray(emptyList()), "target" to JsonPrimitive(-1))
        assertEquals(
            """["let","hidden",["literal",["a"]],["in",["get","id"],["var","hidden"]]]""",
            MapLayersDoc.bind(filter, listOf("hidden"), mapOf("hidden" to JsonArray(listOf(JsonPrimitive("a")))), defaults).toString(),
        )
        assertEquals("""["let","target",-1,["in",["get","id"],["var","hidden"]]]""", MapLayersDoc.bind(filter, listOf("target"), emptyMap(), defaults).toString())
        assertEquals(filter, MapLayersDoc.bind(filter, emptyList(), emptyMap(), defaults))
    }

    @Test
    fun aDocumentThatDoesntParseReadsAsNone() {
        assertNull(MapLayersDoc.parse("not json"))
        assertNull(MapLayersDoc.parse("""{"groups":1}"""))
    }

    @Test
    fun metadataIsReadFromTheStyle() {
        val metadata = StyleMetadata.parse("""{"version":8,"metadata":{"holdmytrack:satellite-road-opacity":0.4}}""")
        assertEquals(JsonPrimitive(0.4), metadata["holdmytrack:satellite-road-opacity"])
        assertTrue(StyleMetadata.parse("[]").isEmpty())
    }
}
