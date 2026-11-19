package dev.holdmytrack.android.recording.db

import dev.holdmytrack.android.net.SyncTrackJson
import dev.holdmytrack.android.net.SyncPointJson
import dev.holdmytrack.android.recording.RecordedPoint

/**
 * One GPS recording, persisted locally by `RecordingService` the moment it stops rather than
 * submitted immediately — submission is a separate, explicit step (ticked on the Sync tab and
 * sent), after which the row is deleted from the device. A failed submit leaves the row as it
 * is, still listed, to be sent again.
 *
 * [id] is the same client-generated UUID used as `external_id` on the wire
 * (`docs/IMPLEMENTATION.md` §4.0.4) — minted once at Start (it keys the recording's journal,
 * `LiveRecordingJournal`, too), stable through edits and retries.
 */
data class RecordedTrackRecord(
    val id: String,
    val name: String,
    val description: String,
    val trackType: String,
    val startedAtMs: Long,
    val distanceMeters: Double,
    val durationSeconds: Long,
    val points: List<RecordedPoint>,
    val createdAtMs: Long,
)

/** The recording as one batch entry of `POST /v2/sync/tracks` (`docs/IMPLEMENTATION.md`
 *  §4.0.3/§4.0.4). */
internal fun RecordedTrackRecord.toSyncTrack() = SyncTrackJson(
    externalId = id,
    trackType = trackType,
    name = name,
    description = description,
    points = points.map { SyncPointJson(lat = it.lat, lon = it.lon, elevationM = it.elevationM?.toDouble(), time = it.time.toString()) },
)

/**
 * The recording as a GPX 1.1 file — `RecordingActivity`'s Download. GPX rather than the sync
 * payload's JSON because it is what every other mapping tool opens, and HoldMyTrack's own upload
 * accepts it too, so a downloaded track can come straight back in. One `<trkseg>`: a pause
 * leaves no gap in [points] to split on, since nothing is recorded while paused.
 */
fun RecordedTrackRecord.toGpx(): String = buildString {
    append("""<?xml version="1.0" encoding="UTF-8"?>""").append('\n')
    append("""<gpx version="1.1" creator="HoldMyTrack" xmlns="http://www.topografix.com/GPX/1/1">""").append('\n')
    append("  <trk>\n")
    if (name.isNotBlank()) append("    <name>").append(xmlEscape(name)).append("</name>\n")
    if (description.isNotBlank()) append("    <desc>").append(xmlEscape(description)).append("</desc>\n")
    append("    <type>").append(xmlEscape(trackType)).append("</type>\n")
    append("    <trkseg>\n")
    for (point in points) {
        append("""      <trkpt lat="${point.lat}" lon="${point.lon}">""")
        point.elevationM?.let { append("<ele>").append(it).append("</ele>") }
        append("<time>").append(point.time).append("</time></trkpt>\n")
    }
    append("    </trkseg>\n")
    append("  </trk>\n")
    append("</gpx>\n")
}

private fun xmlEscape(text: String): String =
    text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")
