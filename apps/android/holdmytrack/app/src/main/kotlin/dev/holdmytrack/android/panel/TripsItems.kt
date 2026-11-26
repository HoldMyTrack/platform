package dev.holdmytrack.android.panel

import dev.holdmytrack.android.net.Trip
import dev.holdmytrack.android.net.TripCopying
import dev.holdmytrack.android.net.TripSend

/** What the Trips list draws, in order: the inbox, folders, the open one's description, statistics and rows, notes. */
sealed class TripsItem(val key: String) {
    data class Folder(val trip: Trip, val open: Boolean, val expanded: Boolean) : TripsItem("folder:" + trip.id)
    data class Description(val tripId: String, val text: String) : TripsItem("description:$tripId")
    data class From(val tripId: String, val text: String) : TripsItem("from:$tripId")
    data class Stats(val trip: Trip) : TripsItem("stats:" + trip.id)
    data class Inbox(val send: TripSend, val answering: Boolean) : TripsItem("inbox:" + send.id)
    /** Keyed by what it is and how many alike come before it, not its place: a copy that finishes
     *  above it doesn't make it another item. */
    data class Copying(val copy: TripCopying, val alike: Int) : TripsItem("copying:${copy.from.length}:${copy.from}:${copy.tripName}:$alike")
    data class Row(val row: TrackRowItem, val tripId: String) : TripsItem("row:" + row.track.id)

    /** Keyed by its place, not its words: two notes with the same words are different items, and
     *  a note never moves between places, which the list's scroll would follow. */
    data class Note(val place: String, val text: String, val failed: Boolean) : TripsItem("note:$place")
}

/** A track's removal from [tripId] that failed, said under that Trip. */
data class RemoveError(val tripId: String, val text: String)

/** The Trips tab's state, as [TripsItems.of] reads it. */
data class TripsState(
    val sends: List<TripSend> = emptyList(),
    val answering: Boolean = false,
    val copying: List<TripCopying> = emptyList(),
    val answerError: String? = null,
    val trips: List<Trip> = emptyList(),
    val ready: Boolean = false,
    val error: String? = null,
    val openId: String? = null,
    val openTrip: Trip? = null,
    val openError: String? = null,
    val foldedId: String? = null,
    val rows: List<TrackRowItem> = emptyList(),
    val rowsLoading: Boolean = false,
    val rowsError: String? = null,
    val removeError: RemoveError? = null,
)

/** The words the list's notes and lines take from the app's strings. */
data class TripsWords(val loading: String, val noneMatch: String, val empty: String, val from: (String) -> String)

object TripsItems {
    /** Whether the list goes back to the top after an update: it was there, and something new
     *  arrived above what was first (a Trip sent, a copy arriving), which the list, keeping its
     *  first item in view, would otherwise leave above it. A row selected changes no first item. */
    fun backToTop(wasAtTop: Boolean, firstBefore: String?, firstAfter: String?): Boolean = wasAtTop && firstAfter != firstBefore

    fun of(state: TripsState, words: TripsWords): List<TripsItem> = with(state) {
        val items = ArrayList<TripsItem>()
        sends.forEach { items += TripsItem.Inbox(it, answering) }
        copying.forEachIndexed { i, copy -> items += TripsItem.Copying(copy, copying.take(i).count { it == copy }) }
        answerError?.let { items += TripsItem.Note("inbox", it, failed = true) }
        val openListed = trips.any { it.id == openId }
        if (openError != null && !openListed) items += TripsItem.Note("open", openError, failed = true)
        for (listed in trips) {
            val open = listed.id == openId
            // The open Trip's own copy is the fresher one.
            val trip = if (open && openTrip?.id == listed.id) openTrip else listed
            val expanded = open && !TripFold.isFolded(foldedId, openId)
            items += TripsItem.Folder(trip, open, expanded)
            // Under its own Trip, folded or not: a failure can land after the Trip folded.
            val removeNote = removeError?.takeIf { it.tripId == trip.id }?.let { TripsItem.Note("remove:${trip.id}", it.text, failed = true) }
            if (!expanded) {
                removeNote?.let { items += it }
                continue
            }
            trip.from?.let { items += TripsItem.From(trip.id, words.from(it)) }
            if (trip.description.isNotEmpty()) items += TripsItem.Description(trip.id, trip.description)
            items += TripsItem.Stats(trip)
            removeNote?.let { items += it }
            rows.forEach { items += TripsItem.Row(it, trip.id) }
            when {
                rowsLoading -> items += TripsItem.Note("rows:${trip.id}", words.loading, failed = false)
                rowsError != null -> items += TripsItem.Note("rows:${trip.id}", rowsError, failed = true)
                // An empty Trip's statistics already say it has no tracks.
                rows.isEmpty() && trip.stats.count > 0 -> items += TripsItem.Note("rows:${trip.id}", words.noneMatch, failed = false)
            }
        }
        when {
            error != null -> items += TripsItem.Note("list", error, failed = true)
            !ready && trips.isEmpty() -> items += TripsItem.Note("list", words.loading, failed = false)
            ready && trips.isEmpty() -> items += TripsItem.Note("list", words.empty, failed = false)
        }
        items
    }
}