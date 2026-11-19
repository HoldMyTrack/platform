package dev.holdmytrack.android.recording.db

import dev.holdmytrack.android.recording.RecordedPoint
import java.time.Instant
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonPrimitive

/**
 * `points_json`, the points as stored before database version 7: an array of
 * `{lat, lon, elevation_m?, time}`. Read once, by the migration that moves them into their own
 * table (`RecordingDbHelper`).
 */
object LegacyPoints {

    /** What `points_json` holds once its points have moved, and what version 7 writes. */
    const val MOVED = "[]"

    /**
     * The points in [json], or null when the row is to be left as it is: already moved (the
     * file went through version 7 before, then an older build), or unreadable. A recording that
     * exists nowhere else is never replaced by nothing.
     */
    fun parse(json: String): List<RecordedPoint>? {
        if (json.isBlank() || json == MOVED) return null
        return runCatching {
            (Json.parseToJsonElement(json) as JsonArray).map { element ->
                val point = element as JsonObject
                RecordedPoint(
                    lat = point.getValue("lat").jsonPrimitive.double,
                    lon = point.getValue("lon").jsonPrimitive.double,
                    elevationM = point["elevation_m"]?.jsonPrimitive?.double?.toFloat(),
                    time = Instant.parse(point.getValue("time").jsonPrimitive.content),
                )
            }
        }.getOrNull()
    }
}
