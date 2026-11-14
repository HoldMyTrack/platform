package dev.holdmytrack.android.map

import android.os.SystemClock
import org.maplibre.android.maps.MapView
import org.maplibre.android.tile.TileOperation

/**
 * Whether satellite imagery is loading on this device (`docs/SPEC.md` FR-4.10): a network that
 * refuses or blocks the imagery host leaves Satellite with its fills hidden over nothing. The web's
 * `satelliteStatus.ts` runs the same cases, `testdata/client-rules/satellite-status.json`.
 */
enum class SatelliteStatus {
    LOADING, LOADED, FAILED;

    companion object {
        /** How long Satellite waits on screen for its first imagery tile. */
        const val WAIT_MS = 15_000L

        fun of(loaded: Boolean, failed: Boolean, waitedMs: Long): SatelliteStatus = when {
            loaded -> LOADED
            failed || waitedMs >= WAIT_MS -> FAILED
            else -> LOADING
        }

        /** Whether the map looks like Satellite, its fills hidden and its roads dimmed. Failed
         *  imagery draws the map as with Satellite off; its layer stays on to notice a tile. */
        fun look(on: Boolean, status: SatelliteStatus): Boolean = on && status != FAILED
    }
}

/**
 * Times the first imagery tile while the map is on screen, between [start] and [stop], and only
 * while [isOn], and hands [onChange] each new [SatelliteStatus]. The basemap's [BasemapWatch].
 */
class SatelliteWatch(
    private val mapView: MapView,
    private val isOn: () -> Boolean,
    private val onChange: (SatelliteStatus) -> Unit,
) {
    private var loaded = false
    private var failed = false
    private var waitedMs = 0L
    private var shown = false
    private var lastTick = 0L
    private var status = SatelliteStatus.LOADING
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
        if (shown) return
        shown = true
        lastTick = SystemClock.elapsedRealtime()
        report()
    }

    fun stop() {
        report()
        shown = false
        mapView.removeCallbacks(tick)
    }

    /** Satellite switched on or off: the wait counts from now, or pauses. */
    fun onSwitched() = report()

    private fun report() {
        val now = SystemClock.elapsedRealtime()
        if (shown && isOn()) waitedMs += now - lastTick
        lastTick = now
        val next = SatelliteStatus.of(loaded, failed, waitedMs)
        mapView.removeCallbacks(tick)
        if (!loaded && shown) mapView.postDelayed(tick, 1_000)
        if (next == status) return
        status = next
        onChange(next)
    }

    private companion object {
        /** The served style's imagery source (`MapSatellite`). */
        const val SOURCE_ID = "satellite"
    }
}
