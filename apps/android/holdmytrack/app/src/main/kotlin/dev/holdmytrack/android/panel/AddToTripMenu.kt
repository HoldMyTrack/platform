package dev.holdmytrack.android.panel

import android.annotation.SuppressLint
import android.content.Context
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.PopupWindow
import android.widget.ScrollView
import android.widget.TextView
import com.google.android.material.checkbox.MaterialCheckBox
import dev.holdmytrack.android.R
import dev.holdmytrack.android.net.FailureText
import dev.holdmytrack.android.net.HoldMyTrackApi
import dev.holdmytrack.android.net.Trip

/**
 * Add to trip's menu under its button (`docs/SPEC.md` FR-13): New trip…, then every Trip,
 * newest first — read each time the menu opens — with how many tracks it holds. One that
 * already holds all of the target is ticked and can't be picked. Picking a Trip adds the target
 * to it in one request and closes the menu; a failure stays in the menu.
 */
class AddToTripMenu(
    private val context: Context,
    private val onTripCreated: (Trip) -> Unit,
    private val onTripsChanged: () -> Unit,
) {
    private val res = context.resources
    private var popup: PopupWindow? = null

    /** The track ids the open menu adds, null while it's closed. */
    var target: List<String>? = null
        private set

    fun dismiss() {
        popup?.dismiss()
    }

    /** Opens the menu under [anchor] for [ids]; [summary] names them in New trip's dialog. */
    @SuppressLint("InflateParams") // A popup's content has no parent to inflate against.
    fun show(anchor: View, ids: List<String>, summary: String) {
        val content = LayoutInflater.from(context).inflate(R.layout.popup_trip_menu, null)
        val rows = content.findViewById<LinearLayout>(R.id.trip_menu_rows)
        val note = content.findViewById<TextView>(R.id.trip_menu_note)
        fun showNote(text: String, failed: Boolean) {
            note.text = text
            note.setTextColor(context.getColor(if (failed) R.color.hmt_danger else R.color.hmt_ink_meta))
            note.visibility = View.VISIBLE
        }
        val popup = PopupWindow(content, ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, true)
        content.findViewById<View>(R.id.trip_menu_new).setOnClickListener {
            popup.dismiss()
            TripSheet.create(context, summary, ids, onTripCreated)
        }
        showNote(res.getString(R.string.panel_loading), failed = false)
        HoldMyTrackApi.trips { result ->
            if (this.popup !== popup) return@trips
            result.onSuccess { trips ->
                note.visibility = View.GONE
                content.findViewById<View>(R.id.trip_menu_divider).visibility = if (trips.isEmpty()) View.GONE else View.VISIBLE
                for (trip in trips) {
                    val row = LayoutInflater.from(context).inflate(R.layout.item_type_filter, rows, false)
                    val holdsAll = trip.trackIds.containsAll(ids)
                    val count = row.findViewById<TextView>(R.id.type_filter_count)
                    row.findViewById<MaterialCheckBox>(R.id.type_filter_check).isChecked = holdsAll
                    row.findViewById<TextView>(R.id.type_filter_label).text = trip.name
                    count.text = PanelFormat.count(res, trip.trackIds.size)
                    row.isEnabled = !holdsAll
                    row.alpha = if (holdsAll) DISABLED_ROW_ALPHA else 1f
                    row.contentDescription = if (holdsAll) "${trip.name}, ${res.getString(R.string.trip_holds_all)}" else trip.name
                    row.setOnClickListener {
                        count.setText(R.string.trip_adding)
                        HoldMyTrackApi.changeTripTracks(trip.id, ids, add = true) { added ->
                            if (this.popup !== popup) return@changeTripTracks
                            added.onSuccess {
                                popup.dismiss()
                                onTripsChanged()
                            }.onFailure { failure ->
                                count.text = PanelFormat.count(res, trip.trackIds.size)
                                showNote(FailureText.of(failure, res.getString(R.string.trip_save_failed)), failed = true)
                            }
                        }
                    }
                    rows.addView(row)
                }
                // About twelve rows, then the list scrolls, as the Type dropdown's does.
                val scroll = content.findViewById<ScrollView>(R.id.trip_menu_scroll)
                rows.measure(View.MeasureSpec.UNSPECIFIED, View.MeasureSpec.UNSPECIFIED)
                val max = (TracksPanel.TYPE_LIST_MAX_DP * res.displayMetrics.density).toInt()
                scroll.layoutParams = scroll.layoutParams.apply {
                    height = if (rows.measuredHeight > max) max else ViewGroup.LayoutParams.WRAP_CONTENT
                }
            }.onFailure { failure ->
                showNote(FailureText.of(failure, res.getString(R.string.trip_load_failed)), failed = true)
            }
        }
        popup.elevation = res.getDimension(R.dimen.hmt_space_8)
        popup.setOnDismissListener {
            this.popup = null
            target = null
        }
        this.popup = popup
        target = ids
        popup.showAsDropDown(anchor, 0, res.getDimensionPixelSize(R.dimen.hmt_space_8))
    }

    private companion object {
        const val DISABLED_ROW_ALPHA = 0.5f
    }
}
