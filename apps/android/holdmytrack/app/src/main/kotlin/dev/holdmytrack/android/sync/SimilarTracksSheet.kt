package dev.holdmytrack.android.sync

import android.annotation.SuppressLint
import android.content.Context
import android.view.LayoutInflater
import android.view.View
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import dev.holdmytrack.android.R
import dev.holdmytrack.android.net.TrackOverlap
import dev.holdmytrack.android.panel.MapSheet
import dev.holdmytrack.android.panel.TrackTypes
import dev.holdmytrack.android.panel.PanelFormat
import dev.holdmytrack.android.panel.typeIcon
import dev.holdmytrack.android.recording.RecordingTypes
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/**
 * Similar tracks (`docs/SPEC.md` FR-3.5; `apps/android/docs/SPEC.md` FR-3.2), `sheet_similar_tracks`
 * in a [MapSheet] that leaves the map in view: a Sync row's ⓘ. What else covers the same time as [of] — rows
 * waiting on this phone ([Similar.waiting]), each picked out on the map when tapped ([onPick]),
 * and the account's track it overlaps the most (`HoldMyTrackApi.trackOverlaps`), opened on
 * the Tracks tab ([onOpen]). It says what sending both does and chooses nothing. The caller
 * dismisses the returned sheet when its tab goes.
 */
object SimilarTracksSheet {

    @SuppressLint("InflateParams") // MapSheet adds the content to its own body.
    fun show(
        context: Context,
        of: Candidate,
        waiting: List<Candidate>,
        onMap: TrackOverlap?,
        onPick: (Candidate) -> Unit,
        onOpen: (TrackOverlap) -> Unit,
    ): MapSheet {
        val res = context.resources
        val content = LayoutInflater.from(context).inflate(R.layout.sheet_similar_tracks, null)
        val sheet = MapSheet(context, res.getString(R.string.similar_title), res.getString(R.string.similar_close), content)

        content.findViewById<TextView>(R.id.similar_lead).text =
            res.getString(R.string.similar_lead, title(context, of), meta(context, of))

        val waitingList: LinearLayout = content.findViewById(R.id.similar_waiting)
        for (candidate in waiting) {
            waitingList.addView(row(context, waitingList, candidate.trackType, title(context, candidate), meta(context, candidate)) {
                sheet.dismiss()
                onPick(candidate)
            })
        }
        val anyWaiting = waiting.isNotEmpty()
        content.findViewById<View>(R.id.similar_waiting_label).visibility = if (anyWaiting) View.VISIBLE else View.GONE
        waitingList.visibility = if (anyWaiting) View.VISIBLE else View.GONE

        val onMapList: LinearLayout = content.findViewById(R.id.similar_on_map)
        if (onMap != null) {
            val started = PanelFormat.startedAt(res, onMap.startedAt, onMap.timezone)
            val named = onMap.name.isNotBlank()
            val meta = listOfNotNull(started.takeIf { named }, TrackTypes.label(onMap.trackType)).joinToString(" · ")
            onMapList.addView(row(context, onMapList, onMap.trackType, if (named) onMap.name.trim() else started, meta) {
                sheet.dismiss()
                onOpen(onMap)
            })
        }
        content.findViewById<View>(R.id.similar_on_map_label).visibility = if (onMap != null) View.VISIBLE else View.GONE
        onMapList.visibility = if (onMap != null) View.VISIBLE else View.GONE

        sheet.show()
        return sheet
    }

    private fun row(context: Context, parent: LinearLayout, type: String, title: String, meta: String, onClick: () -> Unit): View =
        LayoutInflater.from(context).inflate(R.layout.item_similar_track, parent, false).apply {
            findViewById<ImageView>(R.id.similar_icon).setImageResource(typeIcon(type))
            findViewById<TextView>(R.id.similar_title).text = title
            findViewById<TextView>(R.id.similar_meta).text = meta
            contentDescription = context.getString(R.string.similar_show_named, title, meta)
            setOnClickListener { onClick() }
        }

    /** A waiting row's name, or its day and time when it has none — as its Sync row is titled. */
    private fun title(context: Context, candidate: Candidate): String =
        candidate.name.takeIf { it.isNotBlank() } ?: dateTime(candidate)

    private fun meta(context: Context, candidate: Candidate): String {
        val res = context.resources
        return listOfNotNull(
            dateTime(candidate).takeIf { candidate.name.isNotBlank() },
            PanelFormat.distance(res, candidate.distanceM),
            TrackTypes.label(candidate.trackType),
            res.getString(if (candidate.isRecording) R.string.sync_origin_recorded else R.string.sync_origin_health_connect),
        ).joinToString(" · ")
    }

    private fun dateTime(candidate: Candidate): String =
        DATE_FORMAT.withZone(ZoneId.systemDefault()).format(candidate.startedAt)

    private val DATE_FORMAT: DateTimeFormatter = DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT)
}