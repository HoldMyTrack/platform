package dev.holdmytrack.android.panel

import dev.holdmytrack.android.net.Track

/** A DISTANCE band in meters, both ends inclusive. */
data class DistanceRange(val min: Double, val max: Double)

/** The DISTANCE slider's two knobs. */
enum class DistanceKnob { MIN, MAX }

/** One TYPE the listed tracks use, and how many of them do. */
data class TypeFacet(val type: String, val count: Int)

/**
 * The Tracks panel's two client-side filters, TYPE and DISTANCE (`docs/SPEC.md` FR-5.2,
 * FR-5.3). Both narrow a list already fetched for the date range; neither is sent to the server.
 * The web's `trackFacets.ts`; both run `testdata/client-rules`' `distance-bounds.json`,
 * `distance-filter.json`, `type-facets.json` and `passes-filters.json`.
 */
object TrackFacets {

    /** The DISTANCE slider's ends: the shortest and longest track with a distance, or null
     *  when none has one. A private track has none: its stored 0 is no track, not a short one. */
    fun distanceBounds(tracks: List<Track>): DistanceRange? {
        val distances = tracks.filterNot { it.isPrivate }.mapNotNull { it.distanceMeters }
        if (distances.isEmpty()) return null
        return DistanceRange(distances.min(), distances.max())
    }

    /** One kilometer or mile, in meters: the DISTANCE filter moves in whole ones. */
    private fun unitMeters(imperial: Boolean) = if (imperial) 1609.344 else 1000.0

    /** [meters] in units, the floating-point noise of the division taken off, so 10 miles is 10
     *  and not a hair over, which would round up to 11. */
    private fun inUnits(meters: Double, unit: Double) = Math.round(meters / unit * 1e6) / 1e6

    /** The DISTANCE slider's ends (`testdata/client-rules/distance-whole-bounds.json`): [bounds]
     *  rounded outward to whole kilometers or miles, so every track lies within them. */
    fun wholeDistanceBounds(bounds: DistanceRange?, imperial: Boolean): DistanceRange? {
        if (bounds == null) return null
        val unit = unitMeters(imperial)
        return DistanceRange(Math.floor(inUnits(bounds.min, unit)) * unit, Math.ceil(inUnits(bounds.max, unit)) * unit)
    }

    /** [meters] as a DISTANCE slider position, in whole units: the slider moves one unit a step,
     *  and a position off a step is refused, so an end that isn't whole draws at the nearest. */
    fun sliderUnits(meters: Double, imperial: Boolean): Float = Math.round(inUnits(meters, unitMeters(imperial))).toFloat()

    /** A DISTANCE slider position back in meters. */
    fun sliderMeters(units: Float, imperial: Boolean): Double = units.toDouble() * unitMeters(imperial)

    /** The DISTANCE filter after [knob] moved to [value], snapped to a whole kilometer or mile
     *  within [bounds]: the other knob held, the two never crossing, and null — no filter — once
     *  both are back at [bounds], so a knob dragged away and back leaves nothing filtered out. */
    fun nextDistanceFilter(bounds: DistanceRange, current: DistanceRange, knob: DistanceKnob, value: Double, imperial: Boolean): DistanceRange? {
        val unit = unitMeters(imperial)
        val snapped = (Math.round(inUnits(value, unit)) * unit).coerceIn(bounds.min, bounds.max)
        val next = when (knob) {
            DistanceKnob.MIN -> DistanceRange(minOf(snapped, current.max), current.max)
            DistanceKnob.MAX -> DistanceRange(current.min, maxOf(snapped, current.min))
        }
        return next.takeUnless { it.min <= bounds.min && it.max >= bounds.max }
    }

    /** A track with no distance never passes an active band — it can't be placed on it —
     *  and nor does a private one. */
    fun passesDistance(track: Track, filter: DistanceRange?): Boolean {
        if (filter == null) return true
        if (track.isPrivate) return false
        val meters = track.distanceMeters ?: return false
        return meters >= filter.min && meters <= filter.max
    }

    /** The TYPE dropdown's rows: every type among the tracks the DISTANCE band lets
     *  through, busiest first. Counted after DISTANCE, not before, so a count never promises
     *  rows the other filter already removed. */
    fun typeFacets(tracks: List<Track>, distanceFilter: DistanceRange?): List<TypeFacet> {
        val counts = LinkedHashMap<String, Int>()
        for (track in tracks) {
            if (!passesDistance(track, distanceFilter)) continue
            counts.merge(track.trackType, 1, Int::plus)
        }
        return counts.map { (type, count) -> TypeFacet(type, count) }.sortedByDescending { it.count }
    }

    fun passesFilters(track: Track, excludedTypes: Set<String>, distanceFilter: DistanceRange?): Boolean {
        if (track.trackType in excludedTypes) return false
        return passesDistance(track, distanceFilter)
    }
}
