package dev.holdmytrack.android.panel

import dev.holdmytrack.android.net.Track

/** The Edit window's field writes, as values: the web's `fieldWrites` (`ui/editSave.ts`) and iOS's
 *  `EditPlan`. The cases are `testdata/client-rules/edit-writes.json`. */
object EditPlan {

    /** One `PATCH /v2/tracks/{id}`: a full replace of the three fields. */
    data class Write(val id: String, val trackType: String, val name: String, val description: String)

    /**
     * The writes Save makes, in order: one per track whose fields differ from what the server
     * holds, which is what an earlier Save in this window wrote ([written]), else what the window
     * opened with. One track takes all three fields; a group only the type, and an empty [type]
     * ("Mixed types") keeps each its own. One whose
     * last write failed ([unsure]) is written whatever it holds: the server may have taken it and
     * the answer been lost.
     */
    fun writes(tracks: List<Track>, type: String, name: String, description: String, written: Collection<Write>, unsure: Set<String>): List<Write> {
        val picked = type.trim()
        val single = tracks.size == 1
        return tracks.mapNotNull { track ->
            val held = written.lastOrNull { it.id == track.id } ?: Write(track.id, track.trackType, track.name.orEmpty(), track.description.orEmpty())
            val next = if (single) Write(track.id, picked, name.trim(), description) else held.copy(trackType = picked.ifEmpty { held.trackType })
            next.takeIf { it != held || track.id in unsure }
        }
    }
}
