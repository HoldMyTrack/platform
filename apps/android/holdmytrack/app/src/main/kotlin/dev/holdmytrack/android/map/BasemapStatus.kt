package dev.holdmytrack.android.map

import android.os.SystemClock
import org.maplibre.android.maps.MapView
import org.maplibre.android.tile.TileOperation

/**
 * Whether the map says its basemap can't be reached (`docs/SPEC.md` FR-4.5): a network that blocks
 * the tile host stalls its requests, so the map stays blank with no error of its own. The web's
 * `basemapStatus.ts` runs the same cases, `testdata/client-rules/basemap-status.json`.
 */
enum class BasemapStatus {
    LOADING, LOADED, UNREACHABLE;

    companion object {
        /** How long the map waits on screen for its first basemap tile. */
        const val WAIT_MS = 15_000L

        fun of(loaded: Boolean, failed: Boolean, waitedMs: Long): BasemapStatus = when {
            loaded -> LOADED
            failed || waitedMs >= WAIT_MS -> UNREACHABLE
            else -> LOADING
        }
    }
}

/**
 * Times the first basemap tile while the map is on screen, between [start] and [stop], and hands
 * [onChange] each new [BasemapStatus].
 */
class BasemapWatch(private val mapView: MapView, private val onChange: (BasemapStatus) -> Unit) {
    private var loaded = false
    private var failed = false
    private var waitedMs = 0L
    private var shownSince: Long? = null
    private var status = BasemapStatus.LOADING
    private val tick = Runnable { report() }

    init {
        // Tile actions can arrive off the main thread.
        mapView.addOnTileActionListener { op, _, _, _, _, _, sourceId ->
            if (sourceId != SOURCE_ID) return@addOnTileActionListener
            when (op) {
                TileOperation.LoadFromNetwork, TileOperation.LoadFromCache -> mapView.post { loaded = true; report() }
                TileOperation.Error -> mapView.post { failed = true; report() }
                else -> Unit
            }
        }
    }

    fun start() {
        if (loaded || shownSince != null) return
        shownSince = SystemClock.elapsedRealtime()
        report()
    }

    fun stop() {
        shownSince?.let { waitedMs += SystemClock.elapsedRealtime() - it }
        shownSince = null
        mapView.removeCallbacks(tick)
    }

    private fun report() {
        val shown = shownSince?.let { SystemClock.elapsedRealtime() - it } ?: 0L
        val next = BasemapStatus.of(loaded, failed, waitedMs + shown)
        mapView.removeCallbacks(tick)
        if (next == BasemapStatus.LOADING && shownSince != null) mapView.postDelayed(tick, 1_000)
        if (next == status) return
        status = next
        onChange(next)
    }

    private companion object {
        /** The style's basemap source. */
        const val SOURCE_ID = "protomaps"
    }
}
