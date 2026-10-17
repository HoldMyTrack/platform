package dev.holdmytrack.android.map

import android.content.Context
import android.util.Log
import dev.holdmytrack.android.net.HoldMyTrackApi
import dev.holdmytrack.android.net.Session
import java.io.File

/**
 * Where the map's layers document ([MapLayersDoc]) comes from: `GET /v1/map/layers`, revalidated
 * by ETag, and the last one kept on disk, so a cold start draws Fog and the rest straight away
 * from cached tiles, as the stored tile version does (`net/Session.tileVersion`). A kept document
 * is used only at the account's stored tile version, which signing out clears, so one account's
 * never draws another's.
 */
object MapLayersSource {

    private class Kept(val doc: MapLayersDoc.Doc, val etag: String?)

    private val kept = mutableMapOf<String, Kept>()

    private fun file(context: Context, flavor: String) = File(File(context.cacheDir, "map-layers"), "$flavor.json")

    private fun etagFile(context: Context, flavor: String) = File(File(context.cacheDir, "map-layers"), "$flavor.etag")

    /** The last document for [flavor], if it's at the stored tile version. */
    fun last(context: Context, flavor: String): MapLayersDoc.Doc? {
        val entry = kept[flavor] ?: read(context, flavor)?.also { kept[flavor] = it }
        return entry?.doc?.takeIf { it.tileVersion.isNotEmpty() && it.tileVersion == Session.tileVersion }
    }

    /** Asks for [flavor]'s document; [onDoc] gets it when it's new, and nothing on a `304` or a
     *  failure, which leaves the map with what it has. */
    fun fetch(context: Context, flavor: String, onDoc: (MapLayersDoc.Doc) -> Unit) {
        val app = context.applicationContext
        val previous = kept[flavor]
        HoldMyTrackApi.mapLayers(flavor, previous?.etag) { result ->
            result.onFailure { Log.w(TAG, "map layers: ${it.message}") }
            val response = result.getOrNull() ?: return@mapLayers
            val doc = MapLayersDoc.parse(response.text)
            if (doc == null) {
                Log.w(TAG, "map layers: the document doesn't parse")
                return@mapLayers
            }
            kept[flavor] = Kept(doc, response.etag)
            runCatching {
                file(app, flavor).apply { parentFile?.mkdirs() }.writeText(response.text)
                etagFile(app, flavor).writeText(response.etag.orEmpty())
            }
            onDoc(doc)
        }
    }

    private fun read(context: Context, flavor: String): Kept? = runCatching {
        val doc = MapLayersDoc.parse(file(context, flavor).readText()) ?: return null
        Kept(doc, etagFile(context, flavor).readText().ifEmpty { null })
    }.getOrNull()

    private const val TAG = "MapLayersSource"
}
