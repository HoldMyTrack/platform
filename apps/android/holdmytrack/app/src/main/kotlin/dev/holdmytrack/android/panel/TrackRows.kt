package dev.holdmytrack.android.panel

import android.view.View
import android.widget.ImageView
import androidx.annotation.DrawableRes
import android.widget.PopupMenu
import android.widget.TextView
import androidx.appcompat.widget.TooltipCompat
import androidx.core.content.ContextCompat
import androidx.recyclerview.widget.RecyclerView
import android.content.res.ColorStateList
import dev.holdmytrack.android.R
import dev.holdmytrack.android.net.Track
import dev.holdmytrack.android.net.Session
import dev.holdmytrack.android.recording.RecordingTypes

/** One row as drawn: the track and its marks, so a diff rebinds only what changed — a
 *  tick, the selection moving, a refetch — rather than every row, which also cancelled a tap
 *  on another row landing mid-rebind. */
data class TrackRowItem(
    val track: Track,
    val checked: Boolean,
    val focused: Boolean,
    val hidden: Boolean,
    /** Whether the list is selecting — a row's tap then checks or unchecks it. */
    val selecting: Boolean = false,
)

/** The icon for a track's type, on its row's tile and its card: its kind's
 *  ([TrackTypes]). */
@DrawableRes
fun typeIcon(type: String): Int = kindIcon(TrackTypes.kind(type))

@DrawableRes
fun kindIcon(kind: TrackKind): Int = when (kind) {
    TrackKind.FOOT -> R.drawable.ic_footprints
    TrackKind.WHEELS -> R.drawable.ic_bike
    TrackKind.MOTOR -> R.drawable.ic_car
    TrackKind.SOLOWHEEL -> R.drawable.ic_monowheel
    TrackKind.E_SCOOTER -> R.drawable.ic_electric_scooter
    TrackKind.OTHER -> R.drawable.ic_route
}

/**
 * One track row over `item_track_row` — the web's `ActivityRow.tsx`, shared the same way
 * by the Tracks tab and an open Trip's rows on the Trips tab ([TripsTab]). The title
 * and the "[date ·] distance · duration · type" line, dimmed with a Pending or Hidden badge,
 * and a Trip badge for the Trips it's in — all but [openTripId]'s, since every row under
 * an open Trip is in that one (`docs/SPEC.md` FR-5.1). The badge opens its Trip, or, for
 * several, a menu of their names. The tile of its kind is its checkbox, as Gmail's avatar is: a
 * tap on it, or a long press on the row, is [onCheck], and a checked row's tile is a ✓ on the
 * accent; [onCheck] null leaves it a plain tile. [onRemove] shows the × that takes the row out
 * of the open Trip (`docs/SPEC.md` FR-13.6).
 */
class TrackRowHolder(view: View) : RecyclerView.ViewHolder(view) {
    private val res = view.resources
    private val tileTarget: View = view.findViewById(R.id.track_tile_target)
    private val kindTile: ImageView = view.findViewById(R.id.track_type_icon)
    private val text: View = view.findViewById(R.id.track_text)
    private val title: TextView = view.findViewById(R.id.track_title)
    private val meta: TextView = view.findViewById(R.id.track_meta)
    private val badges: View = view.findViewById(R.id.track_badges)
    private val pending: View = view.findViewById(R.id.track_pending)
    private val hidden: View = view.findViewById(R.id.track_hidden)
    private val privateBadge: TextView = view.findViewById<TextView>(R.id.track_private).apply {
        // The web's lock before the word, at the badge's own text size and color.
        val size = textSize.toInt()
        val lock = ContextCompat.getDrawable(context, R.drawable.ic_lock)?.mutate()?.apply {
            setBounds(0, 0, size, size)
            setTint(currentTextColor)
        }
        setCompoundDrawablesRelative(lock, null, null, null)
    }
    private val trip: TextView = view.findViewById(R.id.track_trip)
    private val remove: View = view.findViewById(R.id.track_remove)

    fun bind(
        row: TrackRowItem,
        openTripId: String?,
        onCheck: ((String) -> Unit)?,
        onSelect: (String) -> Unit,
        onOpenTrip: (String) -> Unit,
        onRemove: ((String) -> Unit)? = null,
    ) {
        val track = row.track
        val label = PanelFormat.rowLabel(res, track)
        val named = track.name?.trim()?.isNotEmpty() == true
        val isChecked = row.checked
        val isHidden = row.hidden

        itemView.isSelected = row.focused
        title.text = label
        // The date moves down here once a name has taken the title.
        meta.text = buildString {
            if (named) append(PanelFormat.startedAt(res, track.startedAt, track.timezone)).append(" · ")
            // A private track has no track, so no distance or duration: "0.0 km · 0m" would
            // read as broken data. Its badge says why instead.
            if (!track.isPrivate) {
                append(PanelFormat.distance(res, track.distanceMeters)).append(" · ")
                append(PanelFormat.duration(res, track.movingSeconds)).append(" · ")
            }
            append(TrackTypes.label(track.activityType))
        }
        val dim = when {
            track.pending -> PENDING_ALPHA
            isHidden -> HIDDEN_ALPHA
            else -> 1f
        }
        title.alpha = dim
        meta.alpha = dim
        val others = track.trips.filter { it.id != openTripId }
        val isPrivate = track.isPrivate && !track.pending
        badges.visibility = if (track.pending || isHidden || isPrivate || others.isNotEmpty()) View.VISIBLE else View.GONE
        pending.visibility = if (track.pending) View.VISIBLE else View.GONE
        privateBadge.visibility = if (isPrivate) View.VISIBLE else View.GONE
        TooltipCompat.setTooltipText(privateBadge, res.getString(R.string.track_private_note))
        hidden.visibility = if (isHidden) View.VISIBLE else View.GONE
        val names = others.joinToString(", ") { it.name }
        val tripsNote = when {
            others.isEmpty() -> null
            others.size == 1 -> res.getString(if (openTripId != null) R.string.panel_in_other_trip else R.string.panel_in_trip, names)
            else -> res.getQuantityString(
                if (openTripId != null) R.plurals.panel_in_other_trips else R.plurals.panel_in_trips,
                others.size,
                others.size,
                names,
            )
        }
        trip.visibility = if (others.isEmpty()) View.GONE else View.VISIBLE
        trip.text = if (others.size == 1) {
            res.getString(R.string.panel_trip_badge_one)
        } else {
            res.getQuantityString(R.plurals.panel_trip_badge, others.size, others.size)
        }
        val tripLabel = if (others.size == 1) res.getString(R.string.panel_open_trip, others[0].name) else tripsNote
        trip.contentDescription = tripLabel
        TooltipCompat.setTooltipText(trip, tripLabel)
        trip.setOnClickListener {
            if (others.size == 1) {
                onOpenTrip(others[0].id)
                return@setOnClickListener
            }
            val menu = PopupMenu(trip.context, trip)
            others.forEachIndexed { i, ref -> menu.menu.add(0, i, i, ref.name) }
            menu.setOnMenuItemClickListener { item ->
                onOpenTrip(others[item.itemId].id)
                true
            }
            menu.show()
        }

        remove.visibility = if (onRemove == null) View.GONE else View.VISIBLE
        if (onRemove != null) {
            val demo = Session.isDemo
            remove.isEnabled = !demo
            val removeLabel = res.getString(if (demo) R.string.trip_demo_remove else R.string.trip_remove)
            remove.contentDescription = "$removeLabel: $label"
            TooltipCompat.setTooltipText(remove, removeLabel)
            remove.setOnClickListener { onRemove(track.id) }
        }

        val context = itemView.context
        val ticked = isChecked && onCheck != null
        kindTile.setImageResource(if (ticked) R.drawable.ic_check else typeIcon(track.activityType))
        kindTile.backgroundTintList = if (ticked) ColorStateList.valueOf(context.getColor(R.color.hmt_accent)) else null
        kindTile.imageTintList = ColorStateList.valueOf(context.getColor(if (ticked) R.color.hmt_on_accent else R.color.hmt_ink_secondary))
        val checkLabel = res.getString(if (isChecked) R.string.panel_row_uncheck else R.string.panel_row_check, label)
        // Pending can't be checked until its reprocess lands, though a checked one can still be
        // unchecked.
        val checkable = onCheck != null && (!track.pending || isChecked)
        tileTarget.isClickable = checkable
        tileTarget.isEnabled = checkable
        tileTarget.importantForAccessibility =
            if (onCheck == null) View.IMPORTANT_FOR_ACCESSIBILITY_NO else View.IMPORTANT_FOR_ACCESSIBILITY_YES
        tileTarget.contentDescription = if (onCheck == null) null else checkLabel
        tileTarget.setOnClickListener(if (checkable) View.OnClickListener { onCheck?.invoke(track.id) } else null)

        text.isEnabled = !track.pending
        val action = if (row.selecting) checkLabel else res.getString(R.string.panel_fly_to, label)
        text.contentDescription = listOfNotNull(action, meta.text, tripsNote).joinToString(". ")
        text.setOnClickListener { onSelect(track.id) }
        if (onCheck != null) {
            text.setOnLongClickListener {
                onCheck(track.id)
                true
            }
        } else {
            text.setOnLongClickListener(null)
            text.isLongClickable = false
        }
    }

    private companion object {
        const val PENDING_ALPHA = 0.45f
        const val HIDDEN_ALPHA = 0.55f
    }
}
