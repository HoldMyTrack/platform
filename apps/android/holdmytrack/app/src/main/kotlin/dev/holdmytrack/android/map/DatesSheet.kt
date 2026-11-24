package dev.holdmytrack.android.map

import android.annotation.SuppressLint
import android.text.format.DateFormat
import android.view.LayoutInflater
import android.view.View
import android.widget.TextView
import androidx.core.view.isVisible
import androidx.fragment.app.Fragment
import com.google.android.material.datepicker.CalendarConstraints
import com.google.android.material.datepicker.CompositeDateValidator
import com.google.android.material.datepicker.DateValidatorPointBackward
import com.google.android.material.datepicker.DateValidatorPointForward
import com.google.android.material.datepicker.MaterialDatePicker
import dev.holdmytrack.android.R
import dev.holdmytrack.android.panel.MapSheet
import java.time.LocalDate
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * The Dates filter's From and To (`docs/SPEC.md` FR-5.12) in a [MapSheet], for the map's list or the
 * Library's: each its day or the web's hint, a tap that picks it in a calendar bounded by the first track
 * and today, which applies at once, as the web's does, and ✕ while it's set; Clear dates clears
 * both ([onClear]). What a change does is [DateFilter.setting]'s, reported through [onChange].
 */
class DatesSheet(
    private val fragment: Fragment,
    private val onChange: (DateFilter.End, String?) -> Unit,
    /** Clear dates: both ends at once. */
    private val onClear: () -> Unit,
) {

    private var sheet: MapSheet? = null
    private var content: View? = null
    private var filter = DateFilter.ALL_TIME
    private var bounds = DateFilter.Bounds("", "")
    private var earliest: String? = null
    private var today = ""

    @SuppressLint("InflateParams") // MapSheet adds the content to its own body.
    fun show(filter: DateFilter, bounds: DateFilter.Bounds, earliest: String?, today: String) {
        // A second tap on the chip before the sheet takes input.
        if (sheet != null) return
        this.bounds = bounds
        this.earliest = earliest
        this.today = today
        val context = fragment.requireContext()
        val view = LayoutInflater.from(context).inflate(R.layout.sheet_dates, null)
        content = view
        view.findViewById<View>(R.id.dates_after).setOnClickListener { pick(DateFilter.End.AFTER) }
        view.findViewById<View>(R.id.dates_before).setOnClickListener { pick(DateFilter.End.BEFORE) }
        view.findViewById<View>(R.id.dates_after_clear).setOnClickListener { onChange(DateFilter.End.AFTER, null) }
        view.findViewById<View>(R.id.dates_before_clear).setOnClickListener { onChange(DateFilter.End.BEFORE, null) }
        view.findViewById<View>(R.id.dates_clear).setOnClickListener { onClear() }
        val res = context.resources
        val opened = MapSheet(context, res.getString(R.string.dates_filter), res.getString(R.string.dates_done), view)
        opened.setOnDismiss {
            if (sheet === opened) {
                sheet = null
                content = null
            }
        }
        sheet = opened
        opened.show()
        update(filter)
    }

    /** The filter as the map now has it. */
    fun update(next: DateFilter) {
        filter = next
        val view = content ?: return
        val res = view.resources
        view.findViewById<TextView>(R.id.dates_after_value).text =
            next.after?.let { short(it, today) } ?: earliest?.let { res.getString(R.string.dates_first_track, short(it, today)) }.orEmpty()
        view.findViewById<TextView>(R.id.dates_before_value).text = next.before?.let { short(it, today) } ?: res.getString(R.string.dates_today)
        view.findViewById<View>(R.id.dates_after_clear).apply {
            isVisible = next.after != null
            contentDescription = res.getString(R.string.dates_clear_end, res.getString(R.string.dates_after))
        }
        view.findViewById<View>(R.id.dates_before_clear).apply {
            isVisible = next.before != null
            contentDescription = res.getString(R.string.dates_clear_end, res.getString(R.string.dates_before))
        }
        view.findViewById<View>(R.id.dates_clear).isEnabled = !next.isAllTime
    }

    fun dismiss() = sheet?.dismiss()

    /** The open sheet's top on screen, which a flight fits above. */
    fun topOnScreen(): Int? = sheet?.topOnScreen()

    /** One end at a time in Material's date picker. Its range picker fails both of Dates' rules:
     *  it confirms only with both ends picked, where either may be empty, and applies on Save,
     *  where a change applies at once. */
    private fun pick(end: DateFilter.End) {
        val min = millis(bounds.min)
        val max = millis(bounds.max)
        val current = (if (end == DateFilter.End.AFTER) filter.after else filter.before)
            ?: if (end == DateFilter.End.AFTER) bounds.min else bounds.max
        val constraints = CalendarConstraints.Builder()
            .setStart(min)
            .setEnd(max)
            .setOpenAt(millis(current))
            .setValidator(CompositeDateValidator.allOf(listOf(DateValidatorPointForward.from(min), DateValidatorPointBackward.before(max + DAY_MS))))
            .build()
        val picker = MaterialDatePicker.Builder.datePicker()
            .setTitleText(if (end == DateFilter.End.AFTER) R.string.dates_after else R.string.dates_before)
            .setCalendarConstraints(constraints)
            .setSelection(millis(current))
            .build()
        picker.addOnPositiveButtonClickListener { selected -> onChange(end, day(selected)) }
        picker.show(fragment.childFragmentManager, PICKER_TAG)
    }

    companion object {
        private const val PICKER_TAG = "dates_picker"
        private const val DAY_MS = 86_400_000L

        /** A day as Dates' chip and rows show it: "Jun 3", or "Jun 3, 2025" outside [today]'s
         *  year, in the device's language. */
        fun short(day: String, today: String, locale: Locale = Locale.getDefault()): String {
            val date = runCatching { LocalDate.parse(day) }.getOrNull() ?: return day
            val skeleton = if (day.take(4) == today.take(4)) "MMMd" else "yMMMd"
            return DateTimeFormatter.ofPattern(DateFormat.getBestDateTimePattern(locale, skeleton), locale).format(date)
        }

        /** The picker's UTC midnight for [day]. */
        private fun millis(day: String): Long = LocalDate.parse(day).atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()

        private fun day(millis: Long): String = java.time.Instant.ofEpochMilli(millis).atOffset(ZoneOffset.UTC).toLocalDate().toString()
    }
}