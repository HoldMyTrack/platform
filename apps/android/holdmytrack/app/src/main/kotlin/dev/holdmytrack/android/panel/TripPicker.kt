package dev.holdmytrack.android.panel

import dev.holdmytrack.android.trimWhiteSpace

/** What Add to trip's picker sheet shows ([AddToTripSheet]). */
object TripPicker {
    /** From this many Trips, the sheet has a search field. */
    const val SEARCH_FROM = 9

    /** A Trip as the picker needs it. */
    data class Entry(val id: String, val name: String, val trackIds: List<String>)

    /** A row: [holdsAll] when the Trip has every target track already, so it can't be picked. */
    data class Row(val id: String, val holdsAll: Boolean)

    data class Shown(val search: Boolean, val rows: List<Row>)

    /** The rows for [trips], newest first as the server sends them, over [target], keeping those
     *  whose name holds [query], ignoring case and the whitespace around it. */
    fun shown(trips: List<Entry>, target: List<String>, query: String): Shown {
        val typed = query.trimWhiteSpace()
        val rows = trips.filter { typed.isEmpty() || it.name.contains(typed, ignoreCase = true) }
            .map { Row(it.id, it.trackIds.containsAll(target)) }
        return Shown(search = trips.size >= SEARCH_FROM, rows = rows)
    }
}
