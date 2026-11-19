package dev.holdmytrack.android.map

import android.content.Context
import android.util.Log
import dev.holdmytrack.android.net.HoldMyTrackApi
import dev.holdmytrack.android.net.MapLayersResponse
import dev.holdmytrack.android.net.Session
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * Where the map's layers document ([MapLayersDoc]) comes from: `GET /v2/map/layers`, revalidated
 * by ETag, and the last one kept on disk, so a cold start draws Fog and the rest straight away
 * from cached tiles, as the stored tile version does (`net/Session.tileVersion`). A kept document
 * is used only at the account's stored tile version, which signing out clears, so one account's
 * never draws another's. The files are read ahead at start ([warm]) and written behind, on a
 * thread of their own, so the map's main thread waits on neither.
 */
object MapLayersSource {

    private class Kept(val doc: MapLayersDoc.Doc, val etag: String?)

    /** Read by the main thread, filled by [warm]'s too. */
    private val kept = ConcurrentHashMap<String, Kept>()

    /** One thread, so reads ahead and writes stay in order. */
    private val io = Executors.newSingleThreadExecutor()

    /** Reads every kept document into memory, from `HoldMyTrackApplication` before any map
     *  asks; [last] reads a file itself only if it asks first. */
    fun warm(context: Context) {
        val app = context.applicationContext
        io.execute {
            val names = File(app.cacheDir, DIR).listFiles { f -> f.name.endsWith(".json") }.orEmpty()
            for (name in names) {
                val flavor = name.name.removeSuffix(".json")
                read(app, flavor)?.let { kept.putIfAbsent(flavor, it) }
            }
        }
    }

    private fun file(context: Context, flavor: String) = File(File(context.cacheDir, DIR), "$flavor.json")

    private fun etagFile(context: Context, flavor: String) = File(File(context.cacheDir, DIR), "$flavor.etag")

    /** The last document for [flavor], if it's at the stored tile version. */
    fun last(context: Context, flavor: String): MapLayersDoc.Doc? {
        val entry = kept[flavor] ?: read(context, flavor)?.also { kept[flavor] = it }
        return entry?.doc?.takeIf { it.tileVersion.isNotEmpty() && it.tileVersion == Session.tileVersion }
    }

    /** Any document this process has read, at whatever tile version: for colors only. */
    fun lastAny(): MapLayersDoc.Doc? = kept.values.firstOrNull()?.doc

    /** What a fetch hands the map. */
    sealed interface Outcome {
        /** A new document, to keep and apply. */
        data class Fresh(val doc: MapLayersDoc.Doc, val response: MapLayersResponse) : Outcome

        /** The kept document, which a `304` says is current. */
        data class Current(val doc: MapLayersDoc.Doc) : Outcome

        /** A failure or a body that doesn't parse: the map keeps what it has. */
        data object None : Outcome
    }

    /**
     * [result] of a fetch sent with [kept]'s ETag. A `304` hands back [kept] even when [last]
     * turned it down: the stored tile version is set only once the map has a document, so a
     * kept one at another version (an update, a sign-in again) would otherwise never be applied.
     */
    fun outcome(result: Result<MapLayersResponse?>, kept: MapLayersDoc.Doc?): Outcome {
        val response = result.getOrElse { return Outcome.None }
            ?: return kept?.let { Outcome.Current(it) } ?: Outcome.None
        return MapLayersDoc.parse(response.text)?.let { Outcome.Fresh(it, response) } ?: Outcome.None
    }

    /** Asks for [flavor]'s document; [onDoc] gets it when it's new or confirmed current, and
     *  nothing on a failure, which leaves the map with what it has. */
    fun fetch(context: Context, flavor: String, onDoc: (MapLayersDoc.Doc) -> Unit) {
        val app = context.applicationContext
        val previous = kept[flavor]
        HoldMyTrackApi.mapLayers(flavor, previous?.etag) { result ->
            result.onFailure { Log.w(TAG, "map layers: ${it.message}") }
            when (val outcome = outcome(result, previous?.doc)) {
                is Outcome.Fresh -> {
                    kept[flavor] = Kept(outcome.doc, outcome.response.etag)
                    val text = outcome.response.text
                    val etag = outcome.response.etag.orEmpty()
                    io.execute {
                        runCatching {
                            file(app, flavor).apply { parentFile?.mkdirs() }.writeText(text)
                            etagFile(app, flavor).writeText(etag)
                        }
                    }
                    onDoc(outcome.doc)
                }
                is Outcome.Current -> onDoc(outcome.doc)
                Outcome.None -> if (result.isSuccess) Log.w(TAG, "map layers: the document doesn't parse")
            }
        }
    }

    private fun read(context: Context, flavor: String): Kept? = runCatching {
        val doc = MapLayersDoc.parse(file(context, flavor).readText()) ?: return null
        Kept(doc, etagFile(context, flavor).readText().ifEmpty { null })
    }.getOrNull()

    private const val TAG = "MapLayersSource"
    private const val DIR = "map-layers"
}
