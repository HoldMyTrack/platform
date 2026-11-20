package dev.holdmytrack.android.map

import dev.holdmytrack.android.net.Track

/**
 * The boxes a camera fit over several tracks frames, in their order (`docs/SPEC.md` FR-5.8, the
 * `fitBoxes` rule): the opening view, the Dates flight and a Trip's list flight. A Pending track
 * is left out, and so is a Private one, whose bbox is its location's circle: only focusing that
 * row flies there.
 */
object FitBoxes {
    fun of(tracks: List<Track>): List<List<Double>> = tracks.filter { !it.pending && !it.isPrivate }.mapNotNull { it.bbox }

    /** What Show on map frames (the `selectionBoxes` rule): one track's own bbox, a Private one's
     *  circle included; several, [of]'s, so a circle never joins other tracks' routes. */
    fun selection(tracks: List<Track>): List<List<Double>> =
        if (tracks.size == 1) listOfNotNull(tracks[0].bbox) else of(tracks)
}