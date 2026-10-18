package dev.holdmytrack.android.panel

/** A number to write in the language's digits, with [minDecimals]–[maxDecimals] decimals and
 *  thousands [grouping] or not, followed by [unit]. */
data class DistanceParts(val value: Double, val minDecimals: Int, val maxDecimals: Int, val grouping: Boolean, val unit: DistanceUnit)

enum class DistanceUnit { KM, MI }

/** A duration message: "3h 52m", "43m" or "20s". */
sealed interface DurationParts {
    data class HoursMinutes(val h: Long, val m: Long) : DurationParts
    data class Minutes(val m: Long) : DurationParts
    data class Seconds(val s: Long) : DurationParts
}

/**
 * What [PanelFormat] decides before the language writes it: which number, how many decimals,
 * which unit or message. No Android in it. The web's `formatParts.ts`; both run
 * `testdata/client-rules/distance-parts.json`, `total-distance-parts.json` and
 * `duration-parts.json`.
 */
object FormatParts {

    private const val METERS_PER_MILE = 1609.344

    private fun converted(meters: Double, imperial: Boolean) = if (imperial) meters / METERS_PER_MILE else meters / 1000

    private fun unit(imperial: Boolean) = if (imperial) DistanceUnit.MI else DistanceUnit.KM

    /** An activity's distance: always one decimal, never grouped. */
    fun distance(meters: Double, imperial: Boolean) = DistanceParts(converted(meters, imperial), 1, 1, false, unit(imperial))

    /** A range's total: one decimal below 10 (km or mi), so a short history never reads as a flat
     *  "0 km", and whole units from 10 up. */
    fun totalDistance(meters: Double, imperial: Boolean): DistanceParts {
        val value = converted(meters, imperial)
        return DistanceParts(value, 0, if (value < 10) 1 else 0, true, unit(imperial))
    }

    /** Hours and minutes from an hour up, minutes from a minute, else seconds. */
    fun duration(seconds: Long): DurationParts {
        val h = seconds / 3600
        val m = (seconds % 3600) / 60
        return when {
            h > 0 -> DurationParts.HoursMinutes(h, m)
            m > 0 -> DurationParts.Minutes(m)
            else -> DurationParts.Seconds(seconds)
        }
    }
}
