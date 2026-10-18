package dev.holdmytrack.android.panel

import dev.holdmytrack.android.net.Activity

/** A DISTANCE band in meters, both ends inclusive. */
data class DistanceRange(val min: Double, val max: Double)

/** The DISTANCE slider's two knobs. */
enum class DistanceKnob { MIN, MAX }

/** One TYPE the listed activities use, and how many of them do. */
data class TypeFacet(val type: String, val count: Int)

/**
 * The Activities panel's two client-side filters, TYPE and DISTANCE (`docs/SPEC.md` FR-5.2,
 * FR-5.3). Both narrow a list already fetched for the date range; neither is sent to the server.
 * The web's `activityFacets.ts`; both run `testdata/client-rules`' `distance-bounds.json`,
 * `distance-filter.json`, `type-facets.json` and `passes-filters.json`.
 */
object ActivityFacets {

    /** The DISTANCE slider's ends: the shortest and longest activity with a distance, or null
     *  when none has one. A private activity has none: its stored 0 is no track, not a short one. */
    fun distanceBounds(activities: List<Activity>): DistanceRange? {
        val distances = activities.filterNot { it.isPrivate }.mapNotNull { it.distanceMeters }
        if (distances.isEmpty()) return null
        return DistanceRange(distances.min(), distances.max())
    }

    /** The DISTANCE filter after [knob] moved to [value]: the other knob held, the two never
     *  crossing, and null — no filter — once both are back at [bounds], so a knob dragged away
     *  and back leaves nothing filtered out. */
    fun nextDistanceFilter(bounds: DistanceRange, current: DistanceRange, knob: DistanceKnob, value: Double): DistanceRange? {
        val next = when (knob) {
            DistanceKnob.MIN -> DistanceRange(minOf(value, current.max), current.max)
            DistanceKnob.MAX -> DistanceRange(current.min, maxOf(value, current.min))
        }
        return next.takeUnless { it.min <= bounds.min && it.max >= bounds.max }
    }

    /** An activity with no distance never passes an active band — it can't be placed on it —
     *  and nor does a private one. */
    fun passesDistance(activity: Activity, filter: DistanceRange?): Boolean {
        if (filter == null) return true
        if (activity.isPrivate) return false
        val meters = activity.distanceMeters ?: return false
        return meters >= filter.min && meters <= filter.max
    }

    /** The TYPE dropdown's rows: every type among the activities the DISTANCE band lets
     *  through, busiest first. Counted after DISTANCE, not before, so a count never promises
     *  rows the other filter already removed. */
    fun typeFacets(activities: List<Activity>, distanceFilter: DistanceRange?): List<TypeFacet> {
        val counts = LinkedHashMap<String, Int>()
        for (activity in activities) {
            if (!passesDistance(activity, distanceFilter)) continue
            counts.merge(activity.activityType, 1, Int::plus)
        }
        return counts.map { (type, count) -> TypeFacet(type, count) }.sortedByDescending { it.count }
    }

    fun passesFilters(activity: Activity, excludedTypes: Set<String>, distanceFilter: DistanceRange?): Boolean {
        if (activity.activityType in excludedTypes) return false
        return passesDistance(activity, distanceFilter)
    }
}
