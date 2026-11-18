package dev.holdmytrack.android.net

import dev.holdmytrack.android.map.SpotArea
import java.io.IOException
import java.time.Instant
import okio.source

/**
 * The account's latest copy of its data (root `docs/SPEC.md` FR-1.13), as
 * `GET /v2/account/export` describes it: [state] is "none", "preparing", "ready" or "failed";
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
 * The account as the server describes it — `GET /v2/auth/me`, and the same shape every
 * sign-in answers with and `PATCH /v2/account/settings` returns (`authResponse`,
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

/** `GET /v2/account/settings/options` — the lists Settings chooses from, the server's own, so
 *  a choice is always one the save accepts. */
data class SettingsOptions(
    val countries: List<SettingsOption>,
    val timezones: List<TimezoneGroup>,
    val languages: List<SettingsOption>,
)

/**
 * The optional sign-in methods this deployment has configured (`GET /v2/auth/providers`).
 * [googleClientId] is the server's *web* client ID, which Credential Manager needs as its
 * `serverClientId` for the ID token it returns to be one the server accepts; empty when Google
 * is off.
 */
data class Providers(val google: Boolean, val facebook: Boolean, val googleClientId: String)

/**
 * What the server did with one track in a sync batch. [status] is `"enqueued"`,
 * `"already_processed"` or `"rejected"`, and [error] carries the reason for the last of those —
 * a track with no usable geometry, most often, which is a permanent verdict about that
 * record rather than a transient failure worth retrying.
 */
data class SyncResult(val externalId: String, val status: String, val error: String)

/**
 * What `POST /v2/sync/known` said: the ids the account has from that source, and, of those, the
 * ones still [processing] — sent, their ingest not finished, so not on the map yet.
 */
data class SyncKnown(val known: Set<String>, val processing: Set<String>)

/** What `POST /v2/tracks/upload` said about one file: "enqueued" or "already_processed". */
data class UploadOutcome(val status: String)

/**
 * One row of `GET /v2/tracks` (`docs/IMPLEMENTATION.md` §4.7) — what the map's Tracks
 * panel lists, the web's `Activity`. [startedAt] is the server's RFC 3339 instant, shown in
 * [timezone], the zone it was recorded in (§4.30; empty from an older server). [name],
 * [description], [distanceMeters] and [movingSeconds] are null when the source never set
 * them; [movingSeconds] is moving time, as Trips sum it, else elapsed; [bbox] (`[minLon, minLat, maxLon, maxLat]`) is null for a track with no drawn
 * route. [pending] is a reprocess still running (a route edit, a Private location change):
 * the tracks tile leaves such a row out until it lands (`docs/SPEC.md` FR-5.8). [isPrivate] is a
 * track entirely inside the account's Private locations (FR-5.1): kept, with no route, so its
 * zero distance and duration mean nothing.
 */
data class Track(
    val id: String,
    val startedAt: String,
    val trackType: String,
    val timezone: String = "",
    val name: String?,
    val distanceMeters: Double?,
    val movingSeconds: Long?,
    val description: String?,
    val bbox: List<Double>?,
    val pending: Boolean,
    val edited: Boolean,
    val isPrivate: Boolean = false,
    /** Why Edit route or photos can't be used for it, as the server's code, or null when they
     *  can (`panel/EditAvailability`). */
    val routeEdit: String? = null,
    val photos: String? = null,
    /** The Trips it's in, newest first — what its row's Trip badge names. */
    val trips: List<TripRef> = emptyList(),
)

/** `GET /v2/tracks/area`: the area's newest [tracks], and with an area how many it holds,
 *  more than listed when they were cut at the limit (`docs/SPEC.md` FR-5.11). */
data class AreaPage(val tracks: List<Track>, val total: Int?)

/** One of a track's Trips, as a row of `GET /v2/tracks` names it (`docs/SPEC.md`
 *  FR-5.1). */
data class TripRef(val id: String, val name: String)

/** A copy of a Trip someone sent the account, waiting to be accepted or declined
 *  (`docs/SPEC.md` FR-13.7). [from] is the sender's name, or their email address. */
data class TripSend(val id: String, val tripName: String, val from: String, val trackCount: Int)

/** A copy the account accepted that hasn't finished arriving. */
data class TripCopying(val tripName: String, val from: String)

/** `GET /v2/trip-sends`: the copies waiting, newest first, and the accepted ones arriving. */
data class TripInbox(val sends: List<TripSend>, val copying: List<TripCopying>)

/**
 * A Trip's numbers, or one track type's share of them (`docs/SPEC.md` FR-13.1): [count]
 * tracks, their distance and moving time. [trackType] is empty for the whole Trip.
 */
data class TripTotals(
    val trackType: String,
    val count: Int,
    val distanceMeters: Double,
    val movingSeconds: Long,
)

/**
 * A Trip — a hand-picked set of the account's tracks (`docs/SPEC.md` FR-13.1), the web's
 * `Trip`. [description] is empty when none is set; [from] names who sent the copy it came from
 * (FR-13.8), null for the account's own; [trackIds] is every member, earliest track
 * first; [stats] covers the whole Trip, whatever the date range, and [byType] the same per
 * track type, the most frequent first.
 */
data class Trip(
    val id: String,
    val name: String,
    val description: String,
    val from: String? = null,
    val trackIds: List<String>,
    val stats: TripTotals,
    val byType: List<TripTotals>,
)

/**
 * One vertex of a track's display route, as `GET /v2/tracks/{id}/route-metrics`
 * measures it: its speed from the vertex before, and its moment ([timeS], epoch seconds) —
 * what the Photos tab's slider turns a place on the track into (`docs/SPEC.md` FR-15.4).
 */
data class TrackMetricPoint(
    val lon: Double,
    val lat: Double,
    val speedMps: Double,
    val timeS: Long = 0,
)

/** What the selected track's pace bands are drawn from: its points, and the server's runs of
 *  them by band. */
data class RouteMetrics(
    val trackId: String,
    val points: List<TrackMetricPoint>,
    val bands: List<PaceBand> = emptyList(),
)

/** Points [start]..[end] (inclusive) all in [band], slowest 0; neighbouring runs share their
 *  boundary point, so the coloured pieces join up without a gap. */
data class PaceBand(val band: Int, val start: Int, val end: Int)

/** One recorded point of a track, as `GET /v2/tracks/{id}/route-points` returns it — its
 *  time ([t], Unix ms) is what a route edit names it by. */
data class RoutePoint(val lon: Double, val lat: Double, val t: Long)

/**
 * A route edit, as the server stores and replays it (`docs/IMPLEMENTATION.md` §4.7.7): a point
 * survives when it's inside [keep] (inclusive, null for no limit), outside every [remove]
 * range (inclusive), and not in [drop]; a survivor whose time is a key of [move] is drawn at
 * that lon/lat instead. All times are Unix ms.
 */
data class RouteEdit(
    val keep: Pair<Long, Long>? = null,
    val remove: List<Pair<Long, Long>> = emptyList(),
    val drop: List<Long> = emptyList(),
    val move: Map<Long, Pair<Double, Double>> = emptyMap(),
) {
    val isEmpty: Boolean
        get() = keep == null && remove.isEmpty() && drop.isEmpty() && move.isEmpty()
}

/** A track's recorded points and the edit already applied to them, if any. */
data class RoutePoints(val points: List<RoutePoint>, val edit: RouteEdit?)

/**
 * One photo on a track (`docs/SPEC.md` FR-15.3), always with a place on its track:
 * [routeAt], a moment on it. [lon]/[lat] are that moment's point on the track as drawn, null
 * only for a track with no route left at all. [url] and [thumbUrl] are API paths
 * (`/v2/photos/…`); [width]/[height] are the stored copy's. [timezone] is its track's, which
 * its times are shown in.
 */
data class Photo(
    val id: String,
    val trackId: String,
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
 * What a photo's EXIF said about when and where it was taken, as `POST /v2/photos` and its
 * placement check take it (FR-15.1): [takenAt] an instant, or [takenLocal] a camera clock with
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
 *  FR-15.1): nothing was stored, and it goes again with the user's `route_at`. */
class PhotoNeedsPlaceException(message: String) : IOException(message)

/**
 * One of the account's Private locations (`docs/SPEC.md` FR-7.1): a circle whose contents are
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

/** `GET /v2/coverage/status`: a Fog re-render still to come, the account's map version
 *  (it moves whenever any of its tiles may have), and that version as the `cv` tile URLs carry
 *  ([Session.tileVersion]). */
data class CoverageStatus(val rendering: Boolean, val version: Long, val tileVersion: String, val explored: Explored?)

/** How many places of each Fog level the account has been in, as the map clears them
 *  (`docs/SPEC.md` FR-4.2): the level control's counts ([dev.holdmytrack.android.map.FogLevels]). */
data class Explored(val countries: Int, val regions: Int, val counties: Int, val cities: Int)

/**
 * One Spots place (`docs/SPEC.md` FR-14), as a tile's `spots` feature or `GET /v2/spots` carries
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

/** `GET /v2/spots`: the places in a box, up to the server's cap, and how many there are in all. */
data class SpotsInArea(val spots: List<Spot>, val total: Int)

/** `GET /v2/spots/{id}` (`docs/SPEC.md` FR-14.6): the place, its whole [area] — what capture
 *  mode measures against — and when the account captured it, or null. */
data class SpotDetail(val spot: Spot, val area: SpotArea, val capturedAt: Instant?)

/** One place the account has captured (`GET /v2/spots/captures`, `POST /v2/spots/{id}/captures`). */
data class SpotCapture(val spotId: Long, val capturedAt: Instant)

/** One day that has tracks, as `GET /v2/tracks/histogram` counts it; [date] is `YYYY-MM-DD`
 *  in the account's timezone. Days with none are never returned. */
data class TrackDay(val date: String, val count: Int, val distanceMeters: Double)

/**
 * A page of [TrackDay]s, ascending, and the account's first track day — how far back
 * paging can go, independent of this page's own bounds; null for an account with no tracks.
 */
data class TrackDayPage(val days: List<TrackDay>, val earliest: String?)

/**
 * A request the server answered with a non-2xx status. Every API error is
 * `{"error": code, "message": text}` (`docs/SPEC.md` §1.4): `message` is
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
