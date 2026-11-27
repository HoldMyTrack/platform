package dev.holdmytrack.android.panel

import android.content.res.Resources
import dev.holdmytrack.android.R
import dev.holdmytrack.android.net.Track
import dev.holdmytrack.android.net.Session
import dev.holdmytrack.android.recording.RecordingFormat
import java.text.NumberFormat
import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

/**
 * The Tracks panel's numbers and dates in the app's language: [FormatParts]' decisions
 * written out, and a start time as a medium date with a short time, as the web's `format.ts`
 * does. Units follow the account's Country (`RecordingFormat.imperial`).
 */
object PanelFormat {

    private const val EM_DASH = "—"

    private fun locale(res: Resources): Locale = res.configuration.locales[0] ?: Locale.getDefault()

    /**
     * A moment on this phone, in its time zone: "Oct 11, 2026, 9:39 AM" — the app's language,
     * written the way the account's Country writes a date and a time, as its units follow it
     * (English with Germany: "11 Oct 2026, 09:39"). The language's own way until a Country is
     * saved.
     */
    fun phoneDateTime(res: Resources, at: Instant): String {
        val language = locale(res)
        val written = Session.country.takeIf { it.isNotEmpty() }
            ?.let { runCatching { Locale.Builder().setLocale(language).setRegion(it).build() }.getOrNull() }
            ?: language
        return DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT)
            .withLocale(written)
            .withZone(ZoneId.systemDefault())
            .format(at)
    }

    /** A count, grouped in the app's language, as the web's `toLocaleString`. */
    fun count(res: Resources, n: Int): String = NumberFormat.getIntegerInstance(locale(res)).format(n)

    fun unit(res: Resources): String = unit(res, if (RecordingFormat.imperial()) DistanceUnit.MI else DistanceUnit.KM)

    private fun unit(res: Resources, unit: DistanceUnit): String =
        res.getString(if (unit == DistanceUnit.MI) R.string.panel_unit_mi else R.string.panel_unit_km)

    private fun written(res: Resources, parts: DistanceParts): String =
        NumberFormat.getNumberInstance(locale(res)).apply {
            minimumFractionDigits = parts.minDecimals
            maximumFractionDigits = parts.maxDecimals
            isGroupingUsed = parts.grouping
        }.format(parts.value)

    private fun withUnit(res: Resources, parts: DistanceParts): String = "${written(res, parts)} ${unit(res, parts.unit)}"

    /** The web's `distanceValue`: the number alone. */
    fun distanceValue(res: Resources, meters: Double): String = written(res, FormatParts.distance(meters, RecordingFormat.imperial()))

    /** The web's `distanceBandValue`: an end of the DISTANCE filter's band, the number alone. */
    fun distanceBandValue(res: Resources, meters: Double): String = written(res, FormatParts.distanceBand(meters, RecordingFormat.imperial()))

    /** An end of the DISTANCE slider, with its unit. */
    fun distanceBand(res: Resources, meters: Double): String = withUnit(res, FormatParts.distanceBand(meters, RecordingFormat.imperial()))

    fun distance(res: Resources, meters: Double?): String =
        if (meters == null) EM_DASH else withUnit(res, FormatParts.distance(meters, RecordingFormat.imperial()))

    fun totalDistance(res: Resources, meters: Double): String = withUnit(res, FormatParts.totalDistance(meters, RecordingFormat.imperial()))

    fun duration(res: Resources, seconds: Long?): String = when (val parts = seconds?.let(FormatParts::duration)) {
        null -> EM_DASH
        is DurationParts.HoursMinutes -> res.getString(R.string.panel_duration_hm, parts.h, parts.m)
        is DurationParts.Minutes -> res.getString(R.string.panel_duration_m, parts.m)
        is DurationParts.Seconds -> res.getString(R.string.panel_duration_s, parts.s)
    }

    /** A row's primary line: its name when it has one, else its start time — also how the
     *  toolbar names one selected track. */
    fun rowLabel(res: Resources, track: Track): String =
        track.name?.trim()?.takeIf { it.isNotEmpty() } ?: startedAt(res, track.startedAt, track.timezone)

    /** The zone a track's times are shown in, from its own [timezone] ([TrackZone]). */
    fun zone(timezone: String?): ZoneId = TrackZone.of(timezone, Session.timezone)

    /** "Sep 24, 2026, 4:00 AM", in [timezone], the zone the track was recorded in
     *  (`docs/IMPLEMENTATION.md` §4.30), as the web shows it. */
    fun startedAt(res: Resources, iso: String, timezone: String?): String =
        runCatching {
            DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT)
                .withLocale(locale(res))
                .withZone(zone(timezone))
                .format(OffsetDateTime.parse(iso))
        }.getOrDefault(iso)
}
