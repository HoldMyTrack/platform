package dev.holdmytrack.android.panel

import dev.holdmytrack.android.net.Track

/** Why the Edit window's Track or Photos tab can't be used ([EditAvailability]). */
enum class EditBlock { CHECK_ONE, PENDING, PRIVATE, NO_ORIGINAL, BAD_TIMES }

/**
 * Whether the Edit window's Track and Photos tabs can be used for its tracks. Whether one
 * track allows it is the server's answer (the list's `track_edit` and `photos`, root
 * `docs/SPEC.md` FR-5.7 and FR-15.1); the app adds only the rule that depends on the selection.
 * The web's `ui/editAvailability.ts`.
 */
object EditAvailability {

    /** Edit route needs exactly one track the server allows. */
    fun track(selection: List<Track>): EditBlock? {
        val single = selection.singleOrNull() ?: return EditBlock.CHECK_ONE
        return block(single.routeEdit)
    }

    /** Photos belong to one track the server allows. */
    fun photos(selection: List<Track>): EditBlock? {
        val single = selection.singleOrNull() ?: return EditBlock.CHECK_ONE
        return block(single.photos)
    }

    /** A code the app doesn't know, from a newer server, is left to the server to refuse. */
    private fun block(code: String?): EditBlock? = when (code) {
        "pending" -> EditBlock.PENDING
        "private" -> EditBlock.PRIVATE
        "no_original" -> EditBlock.NO_ORIGINAL
        "bad_times" -> EditBlock.BAD_TIMES
        else -> null
    }
}
