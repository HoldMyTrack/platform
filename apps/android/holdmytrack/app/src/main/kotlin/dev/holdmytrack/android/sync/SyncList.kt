package dev.holdmytrack.android.sync

/**
 * What the Sync tab lists and offers, as values (`apps/android/docs/SPEC.md` FR-3.2, FR-3.4).
 * Sent and not landed yet ([inFlight]): the server knows such a session and a recording is off
 * the phone, so neither is in [SyncCandidates.listed]; they're listed from [SyncProgress]
 * instead, never tickable, and not drawn, since each is drawn as itself once it lands.
 */
data class SyncList(
    /** Everything waiting, hidden or not, and what's on its way, newest first. */
    val everything: List<Candidate>,
    /** What the list shows: hidden rows only with Show hidden, and only the chosen types. */
    val shown: List<Candidate>,
    /** What the map draws dashed. */
    val drawn: List<Candidate>,
    /** What Select all and the count offer: shown, not hidden, not on its way. */
    val tickable: List<Candidate>,
    /** What Sync sends: tickable and ticked. */
    val sendable: List<Candidate>,
    /** What another row can be a double of: not hidden, not on its way. */
    val offered: List<Candidate>,
) {
    companion object {
        fun of(
            sessions: List<Candidate>,
            known: Set<String>,
            recordings: List<Candidate>,
            hidden: Set<String>,
            showHidden: Boolean,
            types: Set<String>,
            inFlight: List<Candidate>,
            ticked: Set<String>,
        ): SyncList {
            val onItsWay = inFlight.mapTo(HashSet()) { it.key }
            fun withInFlight(listed: List<Candidate>) = (listed + inFlight).distinctBy { it.key }.sortedByDescending { it.startedAt }
            val everything = withInFlight(SyncCandidates.listed(sessions, known, recordings, hidden, showHidden = true))
            val shown = withInFlight(SyncCandidates.listed(sessions, known, recordings, hidden, showHidden))
                .filter { types.isEmpty() || it.activityType in types }
            val tickable = shown.filter { it.key !in hidden && it.key !in onItsWay }
            return SyncList(
                everything = everything,
                shown = shown,
                drawn = shown.filterNot { it.key in onItsWay },
                tickable = tickable,
                sendable = tickable.filter { it.key in ticked },
                offered = everything.filter { it.key !in hidden && it.key !in onItsWay },
            )
        }
    }
}