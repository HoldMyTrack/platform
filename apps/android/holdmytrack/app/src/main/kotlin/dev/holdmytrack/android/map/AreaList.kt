package dev.holdmytrack.android.map

import dev.holdmytrack.android.panel.ActivityZone
import java.time.Instant
import java.time.LocalDate
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan
import kotlin.math.ln
import kotlin.math.pow
import kotlin.math.roundToLong
import kotlin.math.sin
import kotlin.math.sinh

/**
 * Whether the list follows the map (`docs/SPEC.md` FR-5.19): from zoom 4, where tracks are drawn,
 * on every settled move; further out there's nothing on the map to list. And whether the last
 * area's list was cut at the limit, so the map draws only the listed tracks and says so. The web's
 * `areaLoad.ts`; both run `testdata/client-rules/area-load.json`.
 */
object AreaLoad {
    /** The most activities one area lists, and so its map draws (the server's areaActivitiesLimit). */
    const val LIMIT = 1000

    /** Where tracks start being drawn, and the list with them ([MapOverlays.TRACKS_MIN_ZOOM]). */
    const val MIN_ZOOM = 4.0

    enum class Load { AUTO, NONE }

    data class Result(val load: Load, val capped: Boolean)

    /** [listed] and [total] are the last load's; [total] is null before one. */
    fun of(zoom: Double, listed: Int, total: Int?): Result =
        Result(if (zoom >= MIN_ZOOM) Load.AUTO else Load.NONE, total != null && total > listed)

    /** Two views the same to about a metre: an area the list was already asked about. */
    fun same(a: List<Double>?, b: List<Double>): Boolean =
        a != null && a.size == 4 && b.size == 4 && a.indices.all { abs(a[it] - b[it]) < 1e-5 }

    /** The visible map as the list's `bbox`, to about a metre, so a redraw asks nothing new. */
    fun box(west: Double, south: Double, east: Double, north: Double): List<Double> =
        listOf(west, south, east, north).map { (it * 1e5).roundToLong() / 1e5 }
}

/**
 * The opening camera (`docs/SPEC.md` FR-4.5): zoom 12, centred on the newest five tracks if they
 * fit the screen there with three quarters of it filled, else the newest four, and so on; when even
 * the newest alone doesn't fit, still centred on it. The web's `openingView.ts`; both run
 * `testdata/client-rules/opening-view.json`.
 */
object OpeningView {
    const val ZOOM = 12.0

    /** How many of the newest activities it tries to show. */
    const val ACTIVITIES = 5

    /** The share of the screen a flight's box may fill. */
    private const val FILL = 0.75

    /** The world's width in the map's pixels at zoom 0. */
    private const val WORLD_PX = 512.0

    data class View(val lon: Double, val lat: Double, val zoom: Double)

    /** [boxes] are the tracks' bounds, newest first; null when there are none. [width] and
     *  [height] are the map's, in the pixels its zoom counts in (dp on Android). */
    fun of(boxes: List<List<Double>>, width: Double, height: Double): View? {
        val newest = boxes.firstOrNull() ?: return null
        val scale = WORLD_PX * 2.0.pow(ZOOM)
        fun frame(b: List<Double>): DoubleArray {
            val (x0, y0) = mercator(b[0], b[3])
            val (x1, y1) = mercator(b[2], b[1])
            return doubleArrayOf((x1 - x0) * scale, (y1 - y0) * scale, (x0 + x1) / 2, (y0 + y1) / 2)
        }
        var chosen = frame(newest)
        for (n in minOf(ACTIVITIES, boxes.size) downTo 1) {
            val union = BoxUnion.of(boxes.take(n)) ?: continue
            val f = frame(union.toList())
            if (f[0] <= width * FILL && f[1] <= height * FILL) {
                chosen = f
                break
            }
        }
        return View(wrapped(chosen[2] * 360 - 180), latitude(chosen[3]), ZOOM)
    }

    /** Web Mercator's x and y of a point, 0..1 across the world, y down. */
    private fun mercator(lon: Double, lat: Double): Pair<Double, Double> {
        val s = sin(lat * PI / 180)
        return (lon + 180) / 360 to 0.5 - ln((1 + s) / (1 - s)) / (4 * PI)
    }

    private fun latitude(y: Double): Double = atan(sinh(PI * (1 - 2 * y))) * 180 / PI

    /** A longitude within -180..180; 180 itself comes back as -180. */
    private fun wrapped(lon: Double): Double = (((lon + 180) % 360) + 360) % 360 - 180
}

/**
 * The Dates filter (`docs/SPEC.md` FR-5.20): From ([after]) and To ([before]), local YYYY-MM-DD
 * dates, both inclusive and either null; both null is all time. The web's `dateFilter.ts`; both
 * run the `date-filter-*` files in `testdata/client-rules`.
 */
data class DateFilter(val after: String? = null, val before: String? = null) {

    enum class End { AFTER, BEFORE }

    /** What its chip says, before wording: all time, both ends, or one. */
    sealed interface Label {
        data object All : Label
        data class Between(val after: String, val before: String) : Label
        data class After(val after: String) : Label
        data class Before(val before: String) : Label
    }

    val label: Label
        get() = when {
            after != null && before != null -> Label.Between(after, before)
            after != null -> Label.After(after)
            before != null -> Label.Before(before)
            else -> Label.All
        }

    val isAllTime: Boolean get() = after == null && before == null

    /** The filter once [end] is set to [value], or cleared with null or empty: clamped into
     *  [bounds], and the other end moved to meet it if they crossed. `fly` asks for the camera to
     *  move onto what it matches once: only setting a date does, never clearing one, nor a value
     *  that changed nothing. */
    fun setting(end: End, value: String?, bounds: Bounds): Change {
        val given = value?.takeIf { it.isNotEmpty() }
        val next = if (given == null) {
            if (end == End.AFTER) copy(after = null) else copy(before = null)
        } else {
            val date = given.coerceIn(bounds.min, bounds.max)
            val set = if (end == End.AFTER) copy(after = date) else copy(before = date)
            if (set.after != null && set.before != null && set.after > set.before) DateFilter(date, date) else set
        }
        return Change(next, next != this && given != null)
    }

    data class Change(val filter: DateFilter, val fly: Boolean)

    data class Bounds(val min: String, val max: String)

    companion object {
        val ALL_TIME = DateFilter()

        /** What the pickers allow: the first activity's day, today without one, to today, the
         *  account's, or the newest activity's day when that's later: one recorded in a zone ahead
         *  can be dated tomorrow. */
        fun bounds(earliest: String?, latest: String?, today: String): Bounds =
            Bounds(earliest?.takeIf { it < today } ?: today, latest?.takeIf { it > today } ?: today)

        /** Today in the account's zone (`docs/SPEC.md` FR-1.7), as YYYY-MM-DD. */
        fun today(zone: String?, now: Instant = Instant.now()): String =
            LocalDate.ofInstant(now, ActivityZone.of(null, zone)).toString()
    }
}