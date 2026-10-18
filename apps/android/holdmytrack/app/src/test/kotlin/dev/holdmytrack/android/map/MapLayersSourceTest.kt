package dev.holdmytrack.android.map

import dev.holdmytrack.android.net.MapLayersResponse
import java.io.File
import java.io.IOException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

/** What a fetch of the layers document hands the map ([MapLayersSource.outcome]). */
class MapLayersSourceTest {

    private val text: String = run {
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        val path = "services/server/internal/mapstyle/layers/light.json"
        while (dir != null && !File(dir, path).isFile) dir = dir.parentFile
        File(dir ?: error("$path not found above ${System.getProperty("user.dir")}"), path).readText()
    }

    private val kept = MapLayersDoc.parse(text) ?: error("layers/light.json doesn't parse")

    @Test
    fun aNewDocumentIsKeptAndApplied() {
        val response = MapLayersResponse(text, "\"e\"")
        val outcome = MapLayersSource.outcome(Result.success(response), null) as MapLayersSource.Outcome.Fresh
        assertSame(response, outcome.response)
        assertEquals(kept.styleBuild, outcome.doc.styleBuild)
    }

    @Test
    fun aNotModifiedHandsBackTheKeptDocument() {
        // The phone's stored tile version may be empty or old (an update, a sign-in again), which
        // made `last` turn the kept document down; the 304 says it is current all the same.
        val outcome = MapLayersSource.outcome(Result.success(null), kept) as MapLayersSource.Outcome.Current
        assertSame(kept, outcome.doc)
    }

    @Test
    fun aNotModifiedWithNothingKeptHandsBackNothing() {
        assertEquals(MapLayersSource.Outcome.None, MapLayersSource.outcome(Result.success(null), null))
    }

    @Test
    fun aFailureOrABodyThatDoesntParseLeavesTheMapAsItIs() {
        assertEquals(MapLayersSource.Outcome.None, MapLayersSource.outcome(Result.failure(IOException("offline")), kept))
        assertEquals(MapLayersSource.Outcome.None, MapLayersSource.outcome(Result.success(MapLayersResponse("{", null)), kept))
    }
}