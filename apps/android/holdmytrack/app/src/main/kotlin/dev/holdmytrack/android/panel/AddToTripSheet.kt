package dev.holdmytrack.android.panel

import android.content.Context
import dev.holdmytrack.android.R
import dev.holdmytrack.android.net.FailureText
import dev.holdmytrack.android.net.HoldMyTrackApi
import dev.holdmytrack.android.net.Trip

/**
 * Add to trip (`docs/SPEC.md` FR-13) as a [PickerSheet]: New trip…, then every Trip, newest first
 * — read each time the sheet opens — with how many tracks it holds, and a search field once there
 * are many ([TripPicker]). One that already holds all of the target can't be picked. Picking a
 * Trip adds the target to it in one request and closes the sheet; a failure stays in the sheet.
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
        val newTrip = PickerSheet.Item(NEW_TRIP, res.getString(R.string.trip_new))
        var trips: List<Trip> = emptyList()
        fun entries() = trips.map { TripPicker.Entry(it.id, it.name, it.trackIds) }
        fun items(query: String): List<PickerSheet.Item> {
            val byId = trips.associateBy { it.id }
            val shown = TripPicker.shown(entries(), ids, query)
            return listOf(newTrip) + shown.rows.map { row ->
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
            if (value == NEW_TRIP) {
                done(null)
                TripSheet.create(context, summary, ids, onTripCreated)
                return@Sending
            }
            HoldMyTrackApi.changeTripTracks(value, ids, add = true) { added ->
                added.onSuccess {
                    done(null)
                    onTripsChanged()
                }.onFailure { failure -> done(FailureText.of(failure, res.getString(R.string.trip_save_failed))) }
            }
        }
        val handle = PickerSheet.show(
            context, res.getString(R.string.trip_add_title), current = "", items = listOf(newTrip), search = null,
            sending = sending,
            onClose = {
                sheet = null
                target = null
            },
        ) {}
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
