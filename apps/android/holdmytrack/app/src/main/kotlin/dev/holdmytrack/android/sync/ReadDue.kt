package dev.holdmytrack.android.sync

import java.time.Duration
import java.time.Instant

/**
 * Whether opening Sync reads Health Connect (`apps/android/docs/SPEC.md` FR-3.2): when it was
 * just switched on and never read, or when its last read is at least [MIN_GAP] old. Refresh reads
 * whatever this says.
 */
object ReadDue {

    /** Opening Sync again within this reads nothing: what was read a moment ago is listed. */
    val MIN_GAP: Duration = Duration.ofMinutes(1)

    fun onOpen(firstLoadPending: Boolean, lastRead: Instant?, now: Instant): Boolean =
        firstLoadPending || lastRead == null || Duration.between(lastRead, now) >= MIN_GAP

    /** Sync back on screen, open all along (from Settings › Sync, an Edit, the app's return, a
     *  failed send): read only when Health Connect was just switched on, whatever the age. */
    fun onReturn(firstLoadPending: Boolean): Boolean = firstLoadPending
}
