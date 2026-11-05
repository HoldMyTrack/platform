package dev.holdmytrack.android.map

import dev.holdmytrack.android.net.PaceBand
import dev.holdmytrack.android.net.TrackMetricPoint
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.ln

/**
 * The pace band rule (`docs/SPEC.md` FR-4.8) for the Sync tab's candidates, which aren't on the
 * server: each speed's log ratio to the track's distance-weighted median, in five bands around it,
 * slowest 0. The server bands every synced activity itself
 * (`GET /v1/activities/{id}/track-metrics`); both run `testdata/pace-bands.json`.
 */
object TrackBands {

    private const val COUNT = 5
    private const val SPREAD_WIDTHS = 2.0
    private const val MIN_WIDTH = 0.10

    /** [points]' runs, each weighing the distance from the point before it. */
    fun runs(points: List<TrackMetricPoint>): List<PaceBand> =
        runs(
            points.map { it.speedMps },
            points.indices.map { i ->
                if (i == 0) 0.0 else Geo.haversineM(points[i - 1].lat, points[i - 1].lon, points[i].lat, points[i].lon)
            },
        )

    /** Point *i*'s band comes from its own speed, and its run starts at point *i − 1*: the
     *  stretch leading into a point is coloured by how fast it was covered. */
    fun runs(speeds: List<Double>, distances: List<Double>): List<PaceBand> {
        val runs = mutableListOf<PaceBand>()
        if (speeds.size < 2) return runs
        val weighed = (1 until speeds.size).filter { speeds[it] > 0 && distances[it] > 0 }
        val typical = weightedMedian(weighed.map { speeds[it] to distances[it] })
        val width = maxOf(
            MIN_WIDTH,
            SPREAD_WIDTHS * weightedMedian(weighed.map { abs(ln(speeds[it] / typical)) to distances[it] }),
        )
        fun band(value: Double) = when {
            typical == 0.0 -> COUNT / 2
            value <= 0 -> 0
            else -> floor(ln(value / typical) / width + COUNT / 2.0).toInt().coerceIn(0, COUNT - 1)
        }
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

    /** The first value, ascending, by which half the weight has passed; 0 with none. */
    private fun weightedMedian(weighted: List<Pair<Double, Double>>): Double {
        val half = weighted.sumOf { it.second } / 2
        var passed = 0.0
        for ((value, weight) in weighted.sortedBy { it.first }) {
            passed += weight
            if (passed >= half) return value
        }
        return 0.0
    }
}
