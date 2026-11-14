package dev.holdmytrack.android.map

import dev.holdmytrack.android.net.Explored

/**
 * Fog's levels (root `docs/IMPLEMENTATION.md` §4.2.4), the web's `fogLevels.ts`: which is in view,
 * what picking one in the level control does, and the zoom each level's layers draw at. Each level
 * draws at every zoom; its band, from the layers document, is where it draws by default. Shared
 * cases: `testdata/client-rules/fog-level-*.json`.
 */
object FogLevels {

    /** A level and its band, from [from] (0 when null) up to but not including [below] (no end
     *  when null), with the layers that draw it and what the account's country calls its places
     *  (Overture's local_type), or null for the generic name. */
    data class Level(
        val level: String,
        val from: Double? = null,
        val below: Double? = null,
        val layers: List<String> = emptyList(),
        val word: String? = null,
    )

    /** What a level is when nothing else is: the finest, drawing every track. */
    const val EXACT = "exact"

    /** Past MapLibre Native's deepest camera zoom (25.5): a range ending here has no end, and one
     *  starting here never draws. The web's 24 is MapLibre GL JS's. */
    private const val MAX_ZOOM = 30f

    /** The level in view: the [locked] one, else the one whose band holds [zoom]. */
    fun inView(levels: List<Level>, zoom: Double, locked: String? = null): String {
        if (locked != null && levels.any { it.level == locked }) return locked
        val inBand = levels.firstOrNull { zoom >= (it.from ?: 0.0) && (it.below == null || zoom < it.below) }
        return inBand?.level ?: levels.lastOrNull()?.level ?: EXACT
    }

    /** The lock after a pick, and the zoom to move the camera out to, keeping its centre, or null
     *  to stay. */
    data class Pick(val locked: String?, val zoom: Double?)

    /** Picking [picked] while [locked] is locked at [zoom]. Picking never zooms in: a level
     *  further in draws where the camera is. */
    fun pick(levels: List<Level>, zoom: Double, locked: String?, picked: String): Pick {
        val band = levels.firstOrNull { it.level == picked } ?: return Pick(locked, null)
        if (picked == locked) return Pick(null, null)
        if (band.below != null && zoom >= band.below) return Pick(picked, band.below)
        return Pick(picked, null)
    }

    /** Each level's layers' zoom range: its band, or with a level locked, every zoom for its
     *  layers and none for the others'. */
    fun zoomRanges(levels: List<Level>, locked: String?): Map<String, ClosedFloatingPointRange<Float>> {
        val lock = locked?.takeIf { l -> levels.any { it.level == l } }
        val ranges = mutableMapOf<String, ClosedFloatingPointRange<Float>>()
        for (l in levels) {
            val range = when {
                lock == null -> (l.from?.toFloat() ?: 0f)..(l.below?.toFloat() ?: MAX_ZOOM)
                l.level == lock -> 0f..MAX_ZOOM
                else -> MAX_ZOOM..MAX_ZOOM
            }
            l.layers.forEach { ranges[it] = range }
        }
        return ranges
    }

    /** How many places of [level] the account has explored, or null for a level that counts
     *  none: exact coverage. */
    fun exploredCount(explored: Explored, level: String): Int? = when (level) {
        "country" -> explored.countries
        "region" -> explored.regions
        "county" -> explored.counties
        "city" -> explored.cities
        else -> null
    }
}