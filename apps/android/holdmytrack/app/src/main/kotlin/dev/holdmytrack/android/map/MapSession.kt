package dev.holdmytrack.android.map

import dev.holdmytrack.android.panel.PanelState

/**
 * Which activities the map's list and tracks show, the visible area under Dates or a Story, and
 * the rules between that scope, the panel's selection ([panel]) and the camera (`docs/SPEC.md`
 * FR-5.19, FR-5.20, FR-14.6): Dates and the area keep the selection, which the next list prunes
 * ([PanelState.setActivities]); setting Dates or opening a Story moves the camera once
 * ([consumeFly]). The web's `session.ts`; both run `testdata/client-rules/web-session.json`.
 */
class MapSession(private val panel: PanelState) {

    /** The Dates filter; all time until set. */
    var dates = DateFilter.ALL_TIME
        private set

    /** The map view the list was last asked about, `[west, south, east, north]`; null until the
     *  opening view settles. */
    var area: List<Double>? = null
        private set

    /** The open Story (`docs/SPEC.md` FR-14.6): the list and tracks are its activities, [dates]
     *  and [area] kept for when it closes. */
    var storyId: String? = null
        private set

    /** The camera moves onto what's shown next: a Story's list, or what Dates match. */
    var flyRequest = false
        private set

    /** Dates changed ([DateFilter.setting]); [fly] moves the camera onto the matches once, never
     *  with a Story open. */
    fun setDates(next: DateFilter, fly: Boolean) {
        dates = next
        flyRequest = fly && storyId == null
    }

    /** The list is asked about this view; false for one it was already asked about. */
    fun areaLoaded(box: List<Double>): Boolean {
        if (AreaLoad.same(area, box)) return false
        area = box
        return true
    }

    /** View on map for an activity not listed: Dates on its own day, and the camera onto it. */
    fun viewDay(day: String) = setDates(DateFilter(day, day), fly = true)

    fun enterStory(id: String) {
        storyId = id
        flyRequest = true
        panel.startOver()
    }

    /** Back to the area and Dates; the camera stays. */
    fun exitStory() {
        storyId = null
        flyRequest = false
        panel.startOver()
    }

    /** Whether a flight was requested, which this answer uses up. */
    fun consumeFly(): Boolean = flyRequest.also { flyRequest = false }

    /** Dates carried through a recreation. */
    fun restore(saved: DateFilter) {
        dates = saved
    }
}
