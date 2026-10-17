package dev.holdmytrack.android.map

import dev.holdmytrack.android.net.PaceBand
import kotlin.math.floor

/**
 * The pace band rule (`docs/SPEC.md` FR-4.8) for the Sync tab's candidates, which aren't on the
 * server: five equal bins over the track's own range of speeds, slowest 0. The server bands every
 * synced activity itself (`GET /v1/activities/track-metrics`); both run
 * `testdata/pace-bands.json`.
 */
object TrackBands {

    private const val COUNT = 5

    /** Point *i*'s band comes from its own speed, and its run starts at point *i − 1*: the
     *  stretch leading into a point is coloured by how fast it was covered. */
    fun runs(speeds: List<Double>): List<PaceBand> {
        val runs = mutableListOf<PaceBand>()
        if (speeds.size < 2) return runs
        val min = speeds.min()
        val span = (speeds.max() - min).takeIf { it != 0.0 } ?: 1.0
        fun band(value: Double) = floor((value - min) / span * COUNT).toInt().coerceIn(0, COUNT - 1)
        var current = -1
        var start = 0
        for (i in 1 until speeds.size) {
            val band = band(speeds[i])
            if (band != current) {
                if (current != -1 && i - 1 > start) runs += PaceBand(current, start, i - 1)
                current = band
                start = i - 1
            }
        }
        if (speeds.size - 1 > start) runs += PaceBand(current, start, speeds.size - 1)
        return runs
    }
}
