package dev.holdmytrack.android.panel

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Typeface
import android.view.Gravity
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.view.isVisible
import androidx.core.widget.doAfterTextChanged
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.google.android.material.appbar.MaterialToolbar
import com.google.android.material.bottomsheet.BottomSheetBehavior
import com.google.android.material.bottomsheet.BottomSheetDialog
import com.google.android.material.textfield.TextInputEditText
import com.google.android.material.textfield.TextInputLayout
import dev.holdmytrack.android.R

/**
 * A list to pick one entry from as a bottom sheet (`sheet_picker`), the app's one picker: the Type
 * field's ([dev.holdmytrack.android.recording.TrackTypePicker]), the You tab's Language and Add to
 * trip ([AddToTripSheet]). A pick applies at once and closes it, so it has no Save, or with
 * [Sending] closes once its request lands; a [lead] row heads the list outside the search, and
 * its pick always closes at once; Back, a swipe or a tap outside close it with nothing
 * picked. With a [Search] it has a search field over the list, which decides the rows
 * shown for what's typed (the Type picker's adds an Add "…" row); the field isn't focused at first,
 * so the keyboard doesn't hide the list, and its Done picks the top row ([doneValue]). The current
 * entry is bold, and the list opens scrolled to it.
 *
 * A `BottomSheetDialog`, not the `BottomSheetDialogFragment` around one, as [FormSheet] is: the
 * callers hand it a callback into the screen that opened it.
 */
object PickerSheet {

    /** A row: [detail] at its end, such as how many tracks use a type. One not [enabled] is shown
     *  dimmed and can't be picked, its [detail] saying why. */
    data class Item(val value: String, val label: String, val detail: String = "", val enabled: Boolean = true)

    /** A pick that sends a request ([run]): the sheet stays open with the row's detail at [busy]
     *  until it answers; done(null) closes it, a failure is shown over the list and any row can be
     *  picked again. */
    class Sending(val busy: String, val run: (value: String, done: (failure: String?) -> Unit) -> Unit)

    /** The search field's hint, the rows for what's typed (all of them while it's blank), and the
     *  line shown when none match. */
    class Search(val hint: String, val rows: (String) -> List<Item>, val noMatch: (String) -> String)

    private const val DISABLED_ROW_ALPHA = 0.5f

    /** Never taller than this much of the screen, so the map or form behind it shows. */
    private const val MAX_HEIGHT_FRACTION = 0.85f

    /** What the keyboard's Done picks: the top row that can be picked once something is typed,
     *  else nothing, so a stray Done can't swap the current entry for whatever heads the list. */
    fun doneValue(typed: String, shown: List<Item>): String? = if (typed.isBlank()) null else shown.firstOrNull { it.enabled }?.value

    /** An open sheet whose rows can change under it, as when the list it shows arrives late. */
    interface Handle {
        /** [items] and [search] in place of the ones it opened with, for what's typed now. */
        fun replace(items: List<Item>, search: Search?)

        /** A line over the list, such as Loading… or why it failed ([failed]); null takes it away. */
        fun note(text: String?, failed: Boolean)

        fun dismiss()
    }

    @SuppressLint("InflateParams") // A dialog's content has no parent to inflate against.
    fun show(
        context: Context,
        title: String,
        current: String,
        items: List<Item>,
        search: Search?,
        sending: Sending? = null,
        lead: Item? = null,
        onClose: () -> Unit = {},
        onPick: (String) -> Unit,
    ): Handle {
        val dialog = BottomSheetDialog(context)
        val content = LayoutInflater.from(context).inflate(R.layout.sheet_picker, null)
        val toolbar: MaterialToolbar = content.findViewById(R.id.picker_toolbar)
        val searchLayout: TextInputLayout = content.findViewById(R.id.picker_search_layout)
        val field: TextInputEditText = content.findViewById(R.id.picker_search)
        val empty: TextView = content.findViewById(R.id.picker_empty)
        val list: RecyclerView = content.findViewById(R.id.picker_list)
        toolbar.title = title

        var pick: (String) -> Unit = {}
        val adapter = Rows(current) { pick(it) }
        adapter.shown = listOfNotNull(lead) + items
        var rows = items
        var searching = search
        var note: Pair<String, Boolean>? = null
        fun render() {
            val typed = field.text.toString().trim()
            val active = searching
            val found = active?.rows(typed) ?: rows
            adapter.shown = listOfNotNull(lead) + found
            val shownNote = note
            when {
                shownNote != null -> {
                    empty.text = shownNote.first
                    empty.setTextColor(context.getColor(if (shownNote.second) R.color.hmt_danger else R.color.hmt_ink_meta))
                }
                active != null -> {
                    empty.text = active.noMatch(typed)
                    empty.setTextColor(context.getColor(R.color.hmt_ink_meta))
                }
            }
            empty.isVisible = shownNote != null || (active != null && found.isEmpty())
        }

        // A second tap while the sheet closes, or while a pick is being sent, is ignored: one
        // pick at a time.
        var picked = false
        pick = pick@{ value ->
            if (picked) return@pick
            picked = true
            val send = sending
            if (send == null || value == lead?.value) {
                dialog.dismiss()
                if (value != current) onPick(value)
                return@pick
            }
            adapter.busy = value to send.busy
            note = null
            render()
            send.run(value) { failure ->
                if (!dialog.isShowing) return@run
                adapter.busy = null
                if (failure == null) {
                    dialog.dismiss()
                } else {
                    picked = false
                    note = failure to true
                    render()
                }
            }
        }
        list.layoutManager = LinearLayoutManager(context)
        list.adapter = adapter

        if (search != null) {
            searchLayout.isVisible = true
            searchLayout.hint = search.hint
            field.doAfterTextChanged {
                // A failed pick's note gives way to what's typed now.
                if (note?.second == true) note = null
                render()
            }
            field.setOnEditorActionListener { _, actionId, _ ->
                if (actionId != EditorInfo.IME_ACTION_DONE) return@setOnEditorActionListener false
                doneValue(field.text.toString(), adapter.shown.filter { it.value != lead?.value })?.let { pick(it) }
                true
            }
        }

        dialog.setOnDismissListener { onClose() }
        dialog.setContentView(content)
        dialog.behavior.skipCollapsed = true
        dialog.behavior.state = BottomSheetBehavior.STATE_EXPANDED
        dialog.behavior.maxHeight = (context.resources.displayMetrics.heightPixels * MAX_HEIGHT_FRACTION).toInt()
        @Suppress("DEPRECATION") // The keyboard lifts the sheet; edge-to-edge insets alone leave it under.
        dialog.window?.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        dialog.show()
        items.indexOfFirst { it.value == current }.takeIf { it > 0 }?.let(list::scrollToPosition)
        return object : Handle {
            override fun replace(items: List<Item>, search: Search?) {
                rows = items
                searching = search
                if (dialog.isShowing) render()
            }

            override fun note(text: String?, failed: Boolean) {
                note = text?.let { it to failed }
                if (dialog.isShowing) render()
            }

            override fun dismiss() = dialog.dismiss()
        }
    }

    private class Rows(private val current: String, private val onPick: (String) -> Unit) : RecyclerView.Adapter<RecyclerView.ViewHolder>() {
        @SuppressLint("NotifyDataSetChanged") // Each search replaces the whole list.
        var shown: List<Item> = emptyList()
            set(value) {
                field = value
                notifyDataSetChanged()
            }

        /** The row being sent ([Sending]) and the detail it shows meanwhile. */
        @SuppressLint("NotifyDataSetChanged") // A row's detail, and every row's enabled state.
        var busy: Pair<String, String>? = null
            set(value) {
                field = value
                notifyDataSetChanged()
            }

        override fun getItemCount() = shown.size

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RecyclerView.ViewHolder {
            val context = parent.context
            val res = context.resources
            val row = LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                minimumHeight = (48 * res.displayMetrics.density).toInt()
                val side = res.getDimensionPixelSize(R.dimen.hmt_space_16)
                val vertical = res.getDimensionPixelSize(R.dimen.hmt_space_12)
                setPadding(side, vertical, side, vertical)
                layoutParams = RecyclerView.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
                isClickable = true
                isFocusable = true
                setBackgroundResource(context.obtainStyledAttributes(intArrayOf(android.R.attr.selectableItemBackground)).run {
                    getResourceId(0, 0).also { recycle() }
                })
                addView(
                    TextView(context).apply { setTextAppearance(R.style.TextAppearance_HoldMyTrack_BodyLarge) },
                    LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f),
                )
                addView(
                    TextView(context).apply {
                        setTextAppearance(R.style.TextAppearance_HoldMyTrack_BodyMedium)
                        alpha = 0.6f
                    },
                )
            }
            return object : RecyclerView.ViewHolder(row) {}
        }

        override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {
            val item = shown[position]
            val row = holder.itemView as LinearLayout
            (row.getChildAt(0) as TextView).apply {
                text = item.label
                // By weight within the theme's own family: setTypeface(null, BOLD) would drop back
                // to the system font.
                typeface = Typeface.create(typeface, if (item.value == current) 700 else 400, false)
            }
            val sending = busy
            (row.getChildAt(1) as TextView).text = if (sending?.first == item.value) sending.second else item.detail
            row.isSelected = item.value == current
            row.isEnabled = item.enabled && sending == null
            row.alpha = if (item.enabled) 1f else DISABLED_ROW_ALPHA
            row.setOnClickListener(if (item.enabled) View.OnClickListener { onPick(item.value) } else null)
        }
    }
}
