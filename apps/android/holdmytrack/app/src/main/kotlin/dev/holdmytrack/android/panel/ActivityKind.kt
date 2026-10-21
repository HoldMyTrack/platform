package dev.holdmytrack.android.panel

/**
 * What kind of moving an activity type is, as the server says (`ActivityTypes`, root
 * `docs/SPEC.md` FR-5.1): its row's and card's icon, and pace or speed.
 */
enum class ActivityKind(val wire: String) {
    /** Walking, hiking, running: pace, minutes per km or mile. */
    FOOT("foot"),

    /** Cycling, skating: speed. */
    WHEELS("wheels"),

    /** Driving, motorcycling: speed. */
    MOTOR("motor"),

    /** On wheels, with an icon of their own. */
    SOLOWHEEL("solowheel"),
    E_SCOOTER("e_scooter"),

    /** Everything else, and a type the server hasn't described yet: speed, the safer reading. */
    OTHER("other");

    /** Pace reads naturally only on foot; everything faster reads as a speed. */
    val showsPace: Boolean get() = this == FOOT

    companion object {
        /** A kind the app doesn't know, from a newer server, is [OTHER]. */
        fun fromWire(value: String): ActivityKind = entries.firstOrNull { it.wire == value } ?: OTHER
    }
}

/** Pace and speed from a distance and a moving time, in a unit [unitMeters] long (a km or a mile). */
object Pace {

    /** Seconds per unit, or null with no distance or no time. */
    fun secondsPerUnit(meters: Double?, seconds: Long?, unitMeters: Double): Double? {
        if (meters == null || seconds == null || meters <= 0 || seconds <= 0) return null
        return seconds / (meters / unitMeters)
    }

    /** "5:27": minutes and seconds, rounded to the second. */
    fun format(secondsPerUnit: Double): String {
        val total = Math.round(secondsPerUnit)
        return "${total / 60}:${(total % 60).toString().padStart(2, '0')}"
    }

    /** Units per hour, or null with no distance or no time. */
    fun speed(meters: Double?, seconds: Long?, unitMeters: Double): Double? {
        if (meters == null || seconds == null || meters <= 0 || seconds <= 0) return null
        return (meters / unitMeters) / (seconds / 3600.0)
    }
}
