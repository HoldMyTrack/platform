package dev.holdmytrack.android.recording

import android.content.Context
import dev.holdmytrack.android.R
import dev.holdmytrack.android.panel.PickerSheet
import dev.holdmytrack.android.panel.TrackTypes

/** One type the account already uses, and how many tracks use it — the same facet the
 *  web client's Tracks panel and Type picker are built from (`trackFacets.ts`). */
data class TypeCount(val type: String, val count: Int)

/**
 * The Type field, in a recording's Edit (`RecordingActivity`) and the Edit window, the web edit
 * dialog's `TrackTypePicker.tsx`, as a [PickerSheet]: the types this account already uses
 * (formatted, with how many tracks use each), filtered as you type ([TypeSearch]), and open-ended:
 * `track_type` is free-form, not a controlled vocabulary, so any search text that doesn't exactly
 * match an existing type offers itself as a last "Add …" row and saves exactly as typed, up to
 * the server's 50-character limit (`maxTrackTypeLen`, `services/server/internal/httpapi/tracks.go`).
 * A current value missing from [known] is still listed, so the current choice is always there.
 */
object TrackTypePicker {

    const val MAX_LENGTH = 50

    fun show(context: Context, current: String, known: List<TypeCount>, onPick: (String) -> Unit) {
        val items = TypeSearch.options(current, known).map { item(it.type, it.count) }
        val byValue = items.associateBy { it.value }
        // [TypeSearch] decides the rows, all of them while blank; this only labels its Add row.
        fun rows(typed: String): List<PickerSheet.Item> {
            val result = TypeSearch.search(items.map { TypeSearch.Option(it.value, it.label) }, typed, MAX_LENGTH)
            val matches = result.shown.map { byValue.getValue(it.value) }
            val add = result.add ?: return matches
            return matches + PickerSheet.Item(add, context.getString(R.string.recording_type_add, add), context.getString(R.string.recording_type_new))
        }
        val search = PickerSheet.Search(
            hint = context.getString(R.string.recording_type_search_hint),
            rows = ::rows,
            noMatch = { typed -> context.getString(R.string.recording_type_no_match, typed) },
        )
        PickerSheet.show(context, context.getString(R.string.recording_type_hint), current, items, search, onPick)
    }

    private fun item(type: String, count: Int) =
        PickerSheet.Item(value = type, label = TrackTypes.label(type).ifEmpty { type }, detail = count.takeIf { it > 0 }?.toString().orEmpty())
}
