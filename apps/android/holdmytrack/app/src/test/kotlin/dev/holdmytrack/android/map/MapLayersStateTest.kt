package dev.holdmytrack.android.map

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test

/** The next account's map draws nothing of the last one's (`apps/docs/SPEC.md` FR-1.3). */
class MapLayersStateTest {

    @Test
    fun `the next account keeps the device's choices and none of the last account's ids`() {
        val ids = JsonArray(listOf(JsonPrimitive("t1")))
        val categories = JsonArray(listOf(JsonPrimitive("viewpoint")))
        val signedIn = MapLayers.State(
            mode = MapMode.entries.last(),
            satellite = true,
            toggles = mapOf("spots" to true),
            vars = mapOf(
                "capped" to JsonPrimitive(true), "listed" to ids, "hidden" to ids, "focused" to ids,
                "captured" to JsonArray(listOf(JsonPrimitive(7))), "captureTarget" to JsonPrimitive(7),
                FogPlaces.VAR to JsonPrimitive("p1"), "spotCategories" to categories,
            ),
            hiddenGroups = mapOf("tracksAside" to setOf("tracks")),
            queries = mapOf("tracks" to "from=2026-01-01"),
            fogLevel = "city",
        )
        assertEquals(
            MapLayers.State(
                mode = MapMode.entries.last(),
                satellite = true,
                toggles = mapOf("spots" to true),
                vars = mapOf("spotCategories" to categories),
            ),
            signedIn.withoutAccount(),
        )
    }
}
