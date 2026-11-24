package dev.holdmytrack.android.panel

import dev.holdmytrack.android.net.TrackPageQuery

/**
 * What the Library tab (`apps/android/docs/SPEC.md` FR-4.1, root `docs/SPEC.md` FR-5.13) decides,
 * as plain values: the request a state asks for, the pager and why a page is empty. The web's
 * `apps/web/src/library/libraryState.ts`; both run `testdata/client-rules/library-*.json`.
 */
object LibraryRules {

    enum class Sort(val key: String) { STARTED("started"), DISTANCE("distance"), MOVING("moving"), ADDED("added") }

    /** Meters; [max] null is unbounded. */
    data class Distance(val min: Double, val max: Double?)

    data class State(
        val sort: Sort = Sort.STARTED,
        val desc: Boolean = true,
        val page: Int = 1,
        val q: String = "",
        /** Types left out, as the Tracks tab's Type filter holds them. */
        val exclude: Set<String> = emptySet(),
        val distance: Distance? = null,
        val after: String? = null,
        val before: String? = null,
        val trip: String? = null,
    ) {
        /** This state after a filter, the search or the sort changed: back on page 1, since the
         *  page the reader was on means something else now. */
        fun withFilter(change: State.() -> State): State = change().copy(page = 1)

        /** Whether any filter or the search is on: the count then says how many match. */
        val anyFilter: Boolean
            get() = q.isNotEmpty() || exclude.isNotEmpty() || distance != null || after != null || before != null || trip != null
    }

    /** The query [state] asks for, given every type the account has ([allTypes], the bounds'):
     *  the Type filter sent as the types kept. Null when every type is left out, which matches
     *  no track. */
    fun pageQuery(state: State, allTypes: List<String>): TrackPageQuery? {
        var types: List<String>? = null
        if (state.exclude.isNotEmpty() && allTypes.isNotEmpty()) {
            types = allTypes.filter { it !in state.exclude }
            if (types.isEmpty()) return null
        }
        return TrackPageQuery(
            page = state.page,
            sort = "${state.sort.key}_${if (state.desc) "desc" else "asc"}",
            q = state.q.ifEmpty { null },
            types = types,
            minDistance = state.distance?.min?.takeIf { it > 0 },
            maxDistance = state.distance?.max,
            from = state.after,
            to = state.before,
            trip = state.trip,
        )
    }

    data class Pager(val from: Int, val to: Int, val prev: Boolean, val next: Boolean)

    /** The rows [page] shows, 1-based, and whether there is a page before and after; null when
     *  it shows no row. */
    fun pager(page: Int, total: Int, pageSize: Int): Pager? {
        val from = (page - 1) * pageSize + 1
        if (total == 0 || from > total) return null
        val to = minOf(page * pageSize, total)
        return Pager(from, to, prev = page > 1, next = to < total)
    }

    enum class EmptyReason { NO_TRACKS, PAST_LAST, SEARCH, SEARCH_AND_FILTERS, FILTERS }

    /** Why a page has no row: no track at all; past the last page, whatever the filters (a Delete
     *  can empty the last page); the search, with or without other filters to clear; or only the
     *  filters. */
    fun emptyReason(state: State, total: Int, anyTrack: Boolean): EmptyReason = when {
        !anyTrack -> EmptyReason.NO_TRACKS
        total > 0 -> EmptyReason.PAST_LAST
        state.q.isNotEmpty() -> if (state.copy(q = "").anyFilter) EmptyReason.SEARCH_AND_FILTERS else EmptyReason.SEARCH
        else -> EmptyReason.FILTERS
    }

    /** Checked after the rows changed: only the ids still listed, since Checked stays within a page. */
    fun keepListed(checked: Set<String>, rows: List<String>): Set<String> = checked.intersect(rows.toSet())
}
