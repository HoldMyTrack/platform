package dev.holdmytrack.android.net

import dev.holdmytrack.android.map.SpotArea
import java.io.IOException
import java.time.Instant
import okio.source

/**
 * The account's latest copy of its data (root `docs/SPEC.md` FR-1.12), as
 * `GET /v1/account/export` describes it: [state] is "none", "preparing", "ready" or "failed";
 * [expiresAt] and [parts] only when ready.
 */
data class ExportStatus(
    val state: String,
    val expiresAt: java.time.Instant?,
    val totalSize: Long,
    val parts: List<ExportPart>,
)

/** One zip archive of an export: [url] is relative to the site, [name] what it saves as. */
data class ExportPart(val n: Int, val size: Long, val name: String, val url: String)

/**
 * The account as the server describes it — `GET /v1/auth/me`, and the same shape every
 * sign-in answers with and `PATCH /v1/account/settings` returns (`authResponse`,
 * `services/server/internal/httpapi/auth.go`). [email] is empty for a demo account, which the
 * server never names. [emailVerified] is false for a new email-and-password account (when the
 * server sends verification emails) and for a new Sign in with Facebook account, until the
 * emailed link is clicked; true for a demo account. [country] is empty until Settings is first
 * saved (the first-run gate); [locale] is empty for "automatic"; [avatarUrl] is an API path, or
 * empty with no avatar.
 */
data class Profile(
    val email: String,
    val isDemo: Boolean,
    val emailVerified: Boolean,
    val displayName: String,
    val country: String,
    val timezone: String,
    val locale: String,
    val avatarUrl: String,
    val imperial: Boolean = false,
)

/** An account with a live session — what a successful sign-in, sign-up or demo start yields. */
data class Account(val token: String, val profile: Profile)

/** One choice in a Settings list: what the server stores, and what to show for it. */
data class SettingsOption(val value: String, val label: String)

/** A region of the Timezone list ("Europe", named in the request's language). */
data class TimezoneGroup(val label: String, val options: List<SettingsOption>)

/** `GET /v1/account/settings/options` — the lists Settings chooses from, the server's own, so
 *  a choice is always one the save accepts. */
data class SettingsOptions(
    val countries: List<SettingsOption>,
    val timezones: List<TimezoneGroup>,
    val languages: List<SettingsOption>,
)

/**
 * The optional sign-in methods this deployment has configured (`GET /v1/auth/providers`).
 * [googleClientId] is the server's *web* client ID, which Credential Manager needs as its
 * `serverClientId` for the ID token it returns to be one the server accepts; empty when Google
 * is off.
 */
data class Providers(val google: Boolean, val facebook: Boolean, val googleClientId: String)

/**
 * What the server did with one activity in a sync batch. [status] is `"enqueued"`,
 * `"already_processed"` or `"rejected"`, and [error] carries the reason for the last of those —
 * an activity with no usable geometry, most often, which is a permanent verdict about that
 * record rather than a transient failure worth retrying.
 */
data class SyncResult(val externalId: String, val status: String, val error: String)

/**
 * What `POST /v1/sync/known` said: the ids the account has from that source, and, of those, the
 * ones still [processing] — sent, their ingest not finished, so not on the map yet.
 */
data class SyncKnown(val known: Set<String>, val processing: Set<String>)

/** What `POST /v1/activities/upload` said about one file: "enqueued" or "already_processed". */
data class UploadOutcome(val status: String)

/**
 * One row of `GET /v1/activities` (`docs/IMPLEMENTATION.md` §4.7) — what the map's Activities
 * panel lists, the web's `Activity`. [startedAt] is the server's RFC 3339 instant, shown in
 * [timezone], the zone it was recorded in (§4.30; empty from an older server). [name],
 * [description], [distanceMeters] and [durationSeconds] are null when the source never set
 * them; [bbox] (`[minLon, minLat, maxLon, maxLat]`) is null for an activity with no drawn
 * track. [pending] is a reprocess still running (a track edit, a Private location change):
 * the tracks tile leaves such a row out until it lands (`docs/SPEC.md` FR-5.15). [isPrivate] is an
 * activity entirely inside the account's Private locations (FR-5.1): kept, with no track, so its
 * zero distance and duration mean nothing.
 */
data class Activity(
    val id: String,
    val startedAt: String,
    val activityType: String,
    val timezone: String = "",
    val name: String?,
    val distanceMeters: Double?,
    val durationSeconds: Long?,
    val description: String?,
    val bbox: List<Double>?,
    val pending: Boolean,
    val edited: Boolean,
    val isPrivate: Boolean = false,
    /** Why Edit track or photos can't be used for it, as the server's code, or null when they
     *  can (`panel/EditAvailability`). */
    val trackEdit: String? = null,
    val photos: String? = null,
    /** The Stories it's in, newest first — what its row's Story badge names. */
    val stories: List<StoryRef> = emptyList(),
)

/** One of an activity's Stories, as a row of `GET /v1/activities` names it (`docs/SPEC.md`
 *  FR-5.1). */
data class StoryRef(val id: String, val name: String)

/** A copy of a Story someone sent the account, waiting to be accepted or declined
 *  (`docs/SPEC.md` FR-14.7). [from] is the sender's name, or their email address. */
data class StorySend(val id: String, val storyName: String, val from: String, val activityCount: Int)

/** A copy the account accepted that hasn't finished arriving. */
data class StoryCopying(val storyName: String, val from: String)

/** `GET /v1/story-sends`: the copies waiting, newest first, and the accepted ones arriving. */
data class StoryInbox(val sends: List<StorySend>, val copying: List<StoryCopying>)

/**
 * A Story's numbers, or one activity type's share of them (`docs/SPEC.md` FR-14.1): [count]
 * activities, their distance and moving time. [activityType] is empty for the whole Story.
 */
data class StoryTotals(
    val activityType: String,
    val count: Int,
    val distanceMeters: Double,
    val movingSeconds: Long,
)

/**
 * A Story — a hand-picked set of the account's activities (`docs/SPEC.md` FR-14.1), the web's
 * `Story`. [description] is empty when none is set; [from] names who sent the copy it came from
 * (FR-14.8), null for the account's own; [activityIds] is every member, earliest activity
 * first; [stats] covers the whole Story, whatever the date range, and [byType] the same per
 * activity type, the most frequent first.
 */
data class Story(
    val id: String,
    val name: String,
    val description: String,
    val from: String? = null,
    val activityIds: List<String>,
    val stats: StoryTotals,
    val byType: List<StoryTotals>,
)

/**
 * One vertex of an activity's display track, as `GET /v1/activities/{id}/track-metrics`
 * measures it: its speed from the vertex before, and its moment ([timeS], epoch seconds) —
 * what the Photos tab's slider turns a place on the track into (`docs/SPEC.md` FR-16.4).
 */
data class TrackMetricPoint(
    val lon: Double,
    val lat: Double,
    val speedMps: Double,
    val timeS: Long = 0,
)

/** What the selected activity's pace bands are drawn from: its points, and the server's runs of
 *  them by band. */
data class TrackMetrics(
    val activityId: String,
    val points: List<TrackMetricPoint>,
    val bands: List<PaceBand> = emptyList(),
)

/** Points [start]..[end] (inclusive) all in [band], slowest 0; neighbouring runs share their
 *  boundary point, so the coloured pieces join up without a gap. */
data class PaceBand(val band: Int, val start: Int, val end: Int)

/** One recorded point of an activity, as `GET /v1/activities/{id}/track-points` returns it — its
 *  time ([t], Unix ms) is what a track edit names it by. */
data class TrackPoint(val lon: Double, val lat: Double, val t: Long)

/**
 * A track edit, as the server stores and replays it (`docs/IMPLEMENTATION.md` §4.7.7): a point
 * survives when it's inside [keep] (inclusive, null for no limit), outside every [remove]
 * range (inclusive), and not in [drop]; a survivor whose time is a key of [move] is drawn at
 * that lon/lat instead. All times are Unix ms.
 */
data class TrackEdit(
    val keep: Pair<Long, Long>? = null,
    val remove: List<Pair<Long, Long>> = emptyList(),
    val drop: List<Long> = emptyList(),
    val move: Map<Long, Pair<Double, Double>> = emptyMap(),
) {
    val isEmpty: Boolean
        get() = keep == null && remove.isEmpty() && drop.isEmpty() && move.isEmpty()
}

/** An activity's recorded points and the edit already applied to them, if any. */
data class TrackPoints(val points: List<TrackPoint>, val edit: TrackEdit?)

/**
 * One photo on an activity (`docs/SPEC.md` FR-16.3), always with a place on its track:
 * [routeAt], a moment on it. [lon]/[lat] are that moment's point on the track as drawn, null
 * only for an activity with no track left at all. [url] and [thumbUrl] are API paths
 * (`/v1/photos/…`); [width]/[height] are the stored copy's. [timezone] is its activity's, which
 * its times are shown in.
 */
data class Photo(
    val id: String,
    val activityId: String,
    val takenAt: Instant?,
    val routeAt: Instant,
    val lon: Double?,
    val lat: Double?,
    val caption: String?,
    val width: Int,
    val height: Int,
    val url: String,
    val thumbUrl: String,
    val timezone: String = "",
)

/**
 * What a photo's EXIF said about when and where it was taken, as `POST /v1/photos` and its
 * placement check take it (FR-16.1): [takenAt] an instant, or [takenLocal] a camera clock with
 * no zone (`YYYY-MM-DDTHH:MM:SS`) — at most one is set — and a position.
 */
data class PhotoExif(
    val takenAt: Instant? = null,
    val takenLocal: String? = null,
    val lat: Double? = null,
    val lon: Double? = null,
)

/** A photo's image, resized for upload: its bytes and their type (`image/webp`, `image/jpeg`). */
class PhotoImage(val bytes: ByteArray, val contentType: String)

/** The server couldn't tell where on the track a photo was taken (`photo_needs_place`,
 *  FR-16.1): nothing was stored, and it goes again with the user's `route_at`. */
class PhotoNeedsPlaceException(message: String) : IOException(message)

/**
 * One of the account's Private locations (`docs/SPEC.md` FR-8.1): a circle whose contents are
 * clipped off the ends of every track. [name] is empty when unset; [radiusM] is between
 * [PrivateLocation.MIN_RADIUS_M] and [PrivateLocation.MAX_RADIUS_M].
 */
data class PrivateLocation(val id: String, val name: String, val lon: Double, val lat: Double, val radiusM: Int) {
    companion object {
        /** The server's own bounds (`private_locations.go`). */
        const val MIN_RADIUS_M = 50
        const val MAX_RADIUS_M = 2000
    }
}

/** `GET /v1/coverage/status`: a Fog/Heatmap re-render still to come, the account's map version
 *  (it moves whenever any of its tiles may have), and that version as the `cv` tile URLs carry
 *  ([Session.tileVersion]). */
data class CoverageStatus(val rendering: Boolean, val version: Long, val tileVersion: String)

/**
 * One Spots place (`docs/SPEC.md` FR-15), as a tile's `spots` feature or `GET /v1/spots` carries
 * it: [category] is the wire name (`playground`, `dog_park`, `monument`, `viewpoint`,
 * `waterfall`, `history`), [lon]/[lat] its anchor, and each text null when OSM has none. [wikipedia] is OSM's
 * tag in its "lang:Article title" form, the only one the server keeps.
 */
data class Spot(
    val id: Long,
    val category: String,
    val name: String?,
    val address: String?,
    val description: String?,
    val inscription: String?,
    val memorial: String?,
    val startDate: String?,
    val wikipedia: String?,
    val lon: Double,
    val lat: Double,
)

/** `GET /v1/spots`: the places in a box, up to the server's cap, and how many there are in all. */
data class SpotsInArea(val spots: List<Spot>, val total: Int)

/** `GET /v1/spots/{id}` (`docs/SPEC.md` FR-15.6): the place, its whole [area] — what capture
 *  mode measures against — and when the account captured it, or null. */
data class SpotDetail(val spot: Spot, val area: SpotArea, val capturedAt: Instant?)

/** One place the account has captured (`GET /v1/spots/captures`, `POST /v1/spots/{id}/captures`). */
data class SpotCapture(val spotId: Long, val capturedAt: Instant)

/** One day that has activity, as `GET /v1/activities/histogram` counts it; [date] is `YYYY-MM-DD`
 *  in the account's timezone. Days with none are never returned. */
data class ActivityDay(val date: String, val count: Int, val distanceMeters: Double)

/**
 * A page of [ActivityDay]s, ascending, and the account's first activity day — how far back
 * paging can go, independent of this page's own bounds; null for an account with no activity.
 */
data class ActivityDayPage(val days: List<ActivityDay>, val earliest: String?)

/**
 * A request the server answered with a non-2xx status. Every API error is
 * `{"error": code, "message": text}` (`docs/adr/0045-one-json-error-shape.md`): `message` is
 * the server's own wording, shown to the user as-is rather than replaced with something vaguer —
 * "invalid email or password" and "an account with this email already exists" are exactly what
 * someone needs to read — and [errorCode] is what a caller branches on, never the message.
 */
class ApiException(val code: Int, message: String, val errorCode: String? = null) :
    IOException(message.ifBlank { "request failed ($code)" }) {
    companion object {
        /**
         * The refusal in a non-2xx [body]: the API's `{error, message}`, its message shown and
         * its code kept, or — from something in front of the server, a proxy's error page — the
         * text as it is, with no code.
         */
        fun from(code: Int, body: String): ApiException {
            val text = body.trim()
            val json = if (text.startsWith("{")) runCatching { apiJson.decodeFromString<ErrorJson>(text) }.getOrNull() else null
            if (json != null && (json.error != null || json.message.isNotEmpty())) {
                return ApiException(code, json.message, json.error?.takeIf { it.isNotEmpty() })
            }
            return ApiException(code, text)
        }
    }
}
