package dev.holdmytrack.android.panel

/**
 * What kind of moving a track type is, as the server says (`TrackTypes`, root
 * `docs/SPEC.md` FR-5.1): its row's icon.
 */
enum class TrackKind(val wire: String) {
    /** Walking, hiking, running. */
    FOOT("foot"),

    /** Cycling, skating. */
    WHEELS("wheels"),

    /** Driving, motorcycling. */
    MOTOR("motor"),

    /** On wheels, with an icon of their own. */
    SOLOWHEEL("solowheel"),
    E_SCOOTER("e_scooter"),

    /** Everything else, and a type the server hasn't described yet. */
    OTHER("other");

    companion object {
        /** A kind the app doesn't know, from a newer server, is [OTHER]. */
        fun fromWire(value: String): TrackKind = entries.firstOrNull { it.wire == value } ?: OTHER
    }
}
