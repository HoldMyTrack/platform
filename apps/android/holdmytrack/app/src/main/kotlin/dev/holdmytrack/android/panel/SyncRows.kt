package dev.holdmytrack.android.panel

import android.content.res.ColorStateList
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.TextView
import androidx.recyclerview.widget.DiffUtil
import androidx.recyclerview.widget.ListAdapter
import androidx.recyclerview.widget.RecyclerView
import dev.holdmytrack.android.R
import dev.holdmytrack.android.net.Session

/** What one Sync row shows ([SyncTab]): compared, unlike a candidate, whose line is an array. */
data class SyncRow(
    val key: String,
    val title: String,
    val meta: String,
    /** "Adding to your map…" while it's on its way ([processing]). */
    val note: String?,
    /** Sent, and not on the map yet (`sync/SyncProgress`): nothing to tick, hide or edit. */
    val processing: Boolean,
    /** How many tracks cover the same time (`docs/SPEC.md` FR-3.5): other rows, and the
     *  account's track it overlaps the most. Its ⓘ shows while there are any. */
    val similar: Int,
    val type: String,
    val recording: Boolean,
    val ticked: Boolean,
    val hidden: Boolean,
    val highlighted: Boolean,
)

/** What a Sync row offers. */
object SyncRowRules {
    /** Ticked to send: not hidden, not on its way already, and never for the demo account. */
    fun tickable(row: SyncRow, demo: Boolean): Boolean = !row.hidden && !row.processing && !demo

    /** Edit and Delete: a recording on the phone. One sent is off the phone already. */
    fun editable(row: SyncRow): Boolean = row.recording && !row.processing
}

/** What a Sync row's controls ask of the tab, by the row's key. */
class SyncRowActions(
    val tick: (key: String) -> Unit,
    val similar: (key: String) -> Unit,
    /** The row's line on the map. */
    val show: (key: String) -> Unit,
    /** A recording's Edit, by its recording id. */
    val edit: (recordingId: String) -> Unit,
    val delete: (key: String) -> Unit,
)

class SyncRowAdapter(private val actions: SyncRowActions) : ListAdapter<SyncRow, SyncRowHolder>(
    object : DiffUtil.ItemCallback<SyncRow>() {
        override fun areItemsTheSame(old: SyncRow, new: SyncRow) = old.key == new.key
        override fun areContentsTheSame(old: SyncRow, new: SyncRow) = old == new
    },
) {
    override fun getItemViewType(position: Int) = TYPE_ROW

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) =
        SyncRowHolder(LayoutInflater.from(parent.context).inflate(R.layout.item_sync_candidate, parent, false), actions)

    override fun onBindViewHolder(holder: SyncRowHolder, position: Int) = holder.bind(getItem(position))

    private companion object {
        const val TYPE_ROW = 1
    }
}

class SyncRowHolder(view: View, private val actions: SyncRowActions) : RecyclerView.ViewHolder(view) {
    private val res = view.resources
    private val tick: View = view.findViewById(R.id.candidate_tick)
    private val icon: ImageView = view.findViewById(R.id.candidate_icon)
    private val text: View = view.findViewById(R.id.candidate_text)
    private val title: TextView = view.findViewById(R.id.candidate_title)
    private val meta: TextView = view.findViewById(R.id.candidate_meta)
    private val note: TextView = view.findViewById(R.id.candidate_note)
    private val similarButton: View = view.findViewById(R.id.candidate_similar)
    private val spinner: View = view.findViewById(R.id.candidate_processing)
    private val hiddenBadge: View = view.findViewById(R.id.candidate_hidden)
    private val edit: View = view.findViewById(R.id.candidate_edit)
    private val delete: View = view.findViewById(R.id.candidate_delete)

    var key: String? = null
        private set

    var processing = false
        private set

    fun bind(row: SyncRow) {
        key = row.key
        processing = row.processing
        itemView.isSelected = row.highlighted
        title.text = row.title
        meta.text = row.meta
        note.text = row.note
        note.visibility = if (row.note != null) View.VISIBLE else View.GONE
        val alpha = if (row.hidden) HIDDEN_ALPHA else 1f
        title.alpha = alpha
        meta.alpha = alpha
        note.alpha = alpha
        hiddenBadge.visibility = if (row.hidden) View.VISIBLE else View.GONE

        val context = itemView.context
        icon.setImageResource(if (row.ticked) R.drawable.ic_check else typeIcon(row.type))
        icon.backgroundTintList = if (row.ticked) ColorStateList.valueOf(context.getColor(R.color.hmt_accent)) else null
        icon.imageTintList = ColorStateList.valueOf(context.getColor(if (row.ticked) R.color.hmt_on_accent else R.color.hmt_ink_secondary))
        // On its way: the tile spins instead of offering a tick.
        icon.visibility = if (row.processing) View.INVISIBLE else View.VISIBLE
        spinner.visibility = if (row.processing) View.VISIBLE else View.GONE
        val tickable = SyncRowRules.tickable(row, Session.isDemo)
        tick.isEnabled = tickable
        tick.isClickable = tickable
        tick.contentDescription = when {
            row.processing -> row.note
            row.ticked -> res.getString(R.string.sync_row_untick, row.title)
            else -> res.getString(R.string.sync_row_tick, row.title)
        }
        tick.setOnClickListener { actions.tick(row.key) }

        similarButton.visibility = if (row.similar > 0) View.VISIBLE else View.GONE
        if (row.similar > 0) {
            similarButton.contentDescription = res.getQuantityString(R.plurals.sync_row_similar, row.similar, row.title, row.similar)
            similarButton.setOnClickListener { actions.similar(row.key) }
        }

        text.contentDescription = listOfNotNull(res.getString(R.string.sync_row_show, row.title), row.meta, row.note).joinToString(". ")
        text.setOnClickListener { actions.show(row.key) }
        text.setOnLongClickListener {
            if (tickable) actions.tick(row.key)
            tickable
        }

        val editable = SyncRowRules.editable(row)
        edit.visibility = if (editable) View.VISIBLE else View.GONE
        delete.visibility = if (editable) View.VISIBLE else View.GONE
        if (editable) {
            // Named per row: TalkBack reads each control on its own, and "Delete" alone
            // doesn't say which recording goes.
            edit.contentDescription = res.getString(R.string.recorded_row_edit_named, row.title)
            delete.contentDescription = res.getString(R.string.recorded_row_delete_named, row.title)
            edit.setOnClickListener { actions.edit(row.key.substringAfter(':')) }
            // Every recording here is unsynced, so Delete discards the only copy — the
            // confirmation says so.
            delete.setOnClickListener { actions.delete(row.key) }
        }
    }

    private companion object {
        const val HIDDEN_ALPHA = 0.55f
    }
}
