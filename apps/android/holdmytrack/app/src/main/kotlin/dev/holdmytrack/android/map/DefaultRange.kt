package dev.holdmytrack.android.map

import dev.holdmytrack.android.panel.ActivityZone
import java.time.Instant
import java.time.LocalDate

/**
 * The default date range (`docs/SPEC.md` FR-6.1): the most recent [DAYS] activity days in the
 * slider's window, through today, the account's ([today]). With no days in the window it starts at
 * the earliest activity, else today. An activity day is in its own zone, so one recorded east of
 * the account's can be later than today; the range then runs to it. The web's
 * `defaultRange.ts`; both run `testdata/client-rules`.
 */
object DefaultRange {
    const val DAYS = 5

    /** [visibleDates] ascending. */
    fun of(visibleDates: List<String>, earliest: String?, today: String): DateRange {
        val recent = visibleDates.takeLast(DAYS)
        val last = recent.lastOrNull()
        return DateRange(recent.firstOrNull() ?: earliest ?: today, if (last != null && last > today) last else today)
    }

    /** The calendar day at [now] in the account's [zone], which decides "today" (`docs/SPEC.md`
     *  FR-1.7); the phone's when it's missing or unknown here ([ActivityZone]). */
    fun today(zone: String?, now: Instant = Instant.now()): String =
        LocalDate.ofInstant(now, ActivityZone.of(null, zone)).toString()
}
