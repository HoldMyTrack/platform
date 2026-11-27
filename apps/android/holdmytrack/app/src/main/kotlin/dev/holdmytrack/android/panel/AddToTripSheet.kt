package dev.holdmytrack.android.panel

import android.content.Context
import android.widget.Toast
import dev.holdmytrack.android.R
import dev.holdmytrack.android.net.FailureText
import dev.holdmytrack.android.net.HoldMyTrackApi
import dev.holdmytrack.android.net.Trip

/**
 * Add to trip (`docs/SPEC.md` FR-13) as a [PickerSheet]: New trip…, then every Trip, newest first
 * — read each time the sheet opens — with how many tracks it holds, and a search field once there
 * are many ([TripPicker]). One that already holds all of the target can't be picked. Picking a
 * Trip adds the target to it in one request, closes the sheet and says so in a Toast; a failure
 * stays in the sheet.
 */
class AddToTripSheet(
    private val context: Context,
    private val onTripCreated: (Trip) -> Unit,
    private val onTripsChanged: () -> Unit,
) {
    private val res = context.resources
    private var sheet: PickerSheet.Handle? = null

    /** The track ids the open sheet adds, null while it's closed. */
    var target: List<String>? = null
        private set

    fun dismiss() {
        sheet?.dismiss()
    }

    /** Opens the sheet for [ids]; [summary] names them in New trip's dialog. */
    fun show(ids: List<String>, summary: String) {
        // A second tap while one is open, or still opening, leaves that one be.
        if (sheet != null) return
        val newTrip = PickerSheet.Item(NEW_TRIP, res.getString(R.string.trip_new))
        var trips: List<Trip> = emptyList()
        fun entries() = trips.map { TripPicker.Entry(it.id, it.name, it.trackIds) }
        fun items(query: String): List<PickerSheet.Item> {
            val byId = trips.associateBy { it.id }
            val shown = TripPicker.shown(entries(), ids, query)
            return shown.rows.map { row ->
                val trip = byId.getValue(row.id)
                PickerSheet.Item(
                    value = row.id,
                    label = trip.name,
                    detail = if (row.holdsAll) res.getString(R.string.trip_holds_all) else PanelFormat.count(res, trip.trackIds.size),
                    enabled = !row.holdsAll,
                )
            }
        }
        val sending = PickerSheet.Sending(res.getString(R.string.trip_adding)) { value, done ->
            HoldMyTrackApi.changeTripTracks(value, ids, add = true) { added ->
                added.onSuccess {
                    done(null)
                    onTripsChanged()
                    trips.find { it.id == value }?.let { trip ->
                        Toast.makeText(context, res.getString(R.string.trip_added, trip.name), Toast.LENGTH_LONG).show()
                    }
                }.onFailure { failure -> done(FailureText.of(failure, res.getString(R.string.trip_save_failed))) }
            }
        }
        var opened: PickerSheet.Handle? = null
        val handle = PickerSheet.show(
            context, res.getString(R.string.trip_add_title), current = "", items = emptyList(), search = null,
            sending = sending,
            lead = newTrip,
            onClose = {
                // Only this sheet's own fields: a later one may be open by now.
                if (sheet === opened) {
                    sheet = null
                    target = null
                }
            },
        ) { value -> if (value == NEW_TRIP) TripSheet.create(context, summary, ids, onTripCreated) }
        opened = handle
        handle.note(res.getString(R.string.panel_loading), failed = false)
        sheet = handle
        target = ids
        HoldMyTrackApi.trips { result ->
            if (sheet !== handle) return@trips
            result.onSuccess { read ->
                trips = read
                handle.note(null, failed = false)
                val search = if (TripPicker.shown(entries(), ids, "").search) {
                    PickerSheet.Search(res.getString(R.string.trip_search_hint), ::items) { typed -> res.getString(R.string.trip_search_none, typed) }
                } else {
                    null
                }
                handle.replace(items(""), search)
            }.onFailure { failure ->
                handle.note(FailureText.of(failure, res.getString(R.string.trip_load_failed)), failed = true)
            }
        }
    }

    private companion object {
        /** New trip…'s row, which no Trip's id can be. */
        const val NEW_TRIP = ":new-trip"
    }
}
