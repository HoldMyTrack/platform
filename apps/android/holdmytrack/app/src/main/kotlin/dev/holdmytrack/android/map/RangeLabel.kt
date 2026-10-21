package dev.holdmytrack.android.map

import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale

/** The selected range as the sheet's heading (`DateRangeSlider`). */
object RangeLabel {

    /**
     * The year said once: "3 Oct 2026", "24 – 28 Sep 2026", "24 Sep – 3 Oct 2026", or
     * "28 Dec 2025 – 3 Jan 2026" across a new year. Months in [locale]'s short form.
     */
    fun of(from: LocalDate, to: LocalDate, locale: Locale): String {
        val dayMonth = DateTimeFormatter.ofPattern("d MMM", locale)
        val dayMonthYear = DateTimeFormatter.ofPattern("d MMM yyyy", locale)
        return when {
            from == to -> dayMonthYear.format(to)
            from.year != to.year -> "${dayMonthYear.format(from)} – ${dayMonthYear.format(to)}"
            from.month == to.month -> "${from.dayOfMonth} – ${dayMonthYear.format(to)}"
            else -> "${dayMonth.format(from)} – ${dayMonthYear.format(to)}"
        }
    }
}
