package dev.holdmytrack.android.map

import dev.holdmytrack.android.net.PaceBand
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.double
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Sync tab's pace bands against the cases the server runs too (`testdata/pace-bands.json`). */
class TrackBandsTest {

    private val file: File = run {
        var at: File? = File(System.getProperty("user.dir")).absoluteFile
        while (at != null && !File(at, "testdata/pace-bands.json").isFile) at = at.parentFile
        File(at ?: error("testdata/pace-bands.json not found above ${System.getProperty("user.dir")}"), "testdata/pace-bands.json")
    }

    @Test
    fun `every shared case holds`() {
        val cases = Json.parseToJsonElement(file.readText()).jsonObject["cases"]!!.jsonArray.map { it.jsonObject }
        assertTrue(cases.isNotEmpty())
        for (case in cases) {
            val speeds = case["input"]!!.jsonObject["speeds"]!!.jsonArray.map { it.jsonPrimitive.double }
            val expected = case["expected"]!!.jsonArray.map {
                val run = it.jsonObject
                PaceBand(run["band"]!!.jsonPrimitive.int, run["start"]!!.jsonPrimitive.int, run["end"]!!.jsonPrimitive.int)
            }
            assertEquals(case["name"]!!.jsonPrimitive.content, expected, TrackBands.runs(speeds))
        }
    }
}
