package dev.holdmytrack.android.panel

import java.time.Instant

/** The Sync list's Health Connect row: when it was last read, with Refresh beside it. */
object SyncSourceRow {

    sealed interface Line {
        /** No row: Health Connect is off, or the notice under it says what to set up. */
        data object Hidden : Line

        /** On, but Health Connect can't be read on this phone and there's nothing to set up. */
        data object NotSetUp : Line

        data object Reading : Line

        data object NotRead : Line

        data class Read(val at: Instant) : Line
    }

    /** [on] is Health Connect switched on for a real account; [setUpNotice] whether the notice
     *  asking for a step in Sync settings shows, which says it better than the row would. */
    fun line(on: Boolean, readable: Boolean, setUpNotice: Boolean, loading: Boolean, checkedAt: Instant?): Line = when {
        !on || setUpNotice -> Line.Hidden
        !readable -> Line.NotSetUp
        loading -> Line.Reading
        checkedAt == null -> Line.NotRead
        else -> Line.Read(checkedAt)
    }

    /** Refresh shows wherever there's something to read, and waits while a read is under way. */
    fun refreshShown(line: Line): Boolean = line is Line.Reading || line is Line.NotRead || line is Line.Read
}
