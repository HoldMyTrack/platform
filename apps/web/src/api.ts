import { t } from './i18n/index.ts';
import { rememberTypeKinds, rememberTypeLabels } from './ui/trackTypes.ts';
import { deleteDone, parseErrorBody } from './apiError.ts';
import type { components, paths } from './apiSchema.ts';
import type { SpotCategory, SpotInArea } from './map/spots.ts';

/**
 * The Go backend's upload endpoint (IMPLEMENTATION.md §4.0).
 * VITE_API_BASE_URL follows the same convention as the rest of the web client's env vars —
 * a committed, non-secret default here, overridable via apps/web/.env.local.
 */
export const API_BASE_URL: string =
  (import.meta.env.VITE_API_BASE_URL as string | undefined) ?? 'http://localhost:8080';

/**
 * The sole place the API's major version lives on this side: the web speaks `/v2`
 * (services/server/api/v2/), and `/v1` is left to the installed apps. The tiles' own prefix is
 * mapLayers.ts's TILES.
 */
const API_V2 = '/v2';

/** A shape the API contract (services/server/api/) names, as `apiSchema.ts` generates it from the
 *  contract (`npm run gen:api-types`). */
type Schema<N extends keyof components['schemas']> = components['schemas'][N];

/** The JSON a `/v2` operation answers `status` with, as the contract states it — what a response
 *  body is read as, in place of a hand-written copy of its shape. */
type ResponseJson<P extends keyof paths, M extends 'get' | 'post' | 'patch' | 'delete', S extends number = 200> =
  NonNullable<paths[P][M]> extends { responses: infer R }
    ? S extends keyof R
      ? R[S] extends { content: { 'application/json': infer B } }
        ? B
        : never
      : never
    : never;

/** `T` with each optional field also taking undefined, which JSON.stringify leaves out: so a
 *  body can pass a value that may be missing without spelling out its absence. */
type Sendable<T> = { [K in keyof T]: T[K] | (undefined extends T[K] ? undefined : never) };

/** The JSON body a `/v2` operation takes, as the contract states it. */
type RequestJson<P extends keyof paths, M extends 'post' | 'patch' | 'delete'> =
  NonNullable<paths[P][M]> extends { requestBody?: infer R }
    ? NonNullable<R> extends { content: { 'application/json': infer B } }
      ? Sendable<B>
      : never
    : never;

/**
 * A request's body for `P`'s `M`, checked against the contract: a field renamed there no longer
 * compiles here, where an untyped literal would go on sending the old name.
 */
function jsonBody<P extends keyof paths, M extends 'post' | 'patch' | 'delete'>(body: RequestJson<P, M>): string {
  return JSON.stringify(body);
}

/** An error response's message, worth putting in front of a person (`parseErrorBody`), for the
 *  `fetch`-based functions below, which all throw through this rather than reading `res.text()`
 *  and constructing an `Error` themselves. One that branches on the code reads the body itself. */
async function errorMessageFromResponse(res: Response, fallback: string): Promise<string> {
  const text = await res.text().catch(() => '');
  return parseErrorBody(text, fallback).message;
}

/**
 * Simple email+password auth (services/server/internal/httpapi/auth.go) — every request in
 * this file sends `credentials: 'include'` so the browser attaches the session cookie these
 * endpoints set/read.
 * Signing in, signing up, password reset and email verification are server-rendered pages
 * (ADR-0012), not calls from here, and so is signing out (the page header's form); this app
 * only reads the session (`getCurrentUser`).
 */
/** The Settings page's own fields (`/settings`) — carried by both `AuthUser` and
 *  `DemoUser` uniformly, since a demo account is a real `users` row with real column
 *  defaults, not a special case that skips having them. `displayName`/`country`/`avatarUrl`
 *  are `''` when unset, not `undefined` — every caller checks
 *  for an empty string, never an absent field. `country` is an ISO 3166-1 alpha-2 code or
 *  `''`; the server derives `unitSystem` from it, metric when it's `''`. `avatarUrl` is already a
 *  full API path (`/v2/account/avatar?v=...`) — callers prefix `API_BASE_URL`. */
export interface UserProfile {
  displayName: string;
  country: string;
  avatarUrl: string;
  /** IANA zone name (e.g. "America/New_York"), never `''` — unlike displayName/country there
   *  is no "unset" state (services/server/migrations/0001_users_and_auth.sql's column is
   *  `NOT NULL DEFAULT 'UTC'`). Decides "today" server-side and stands in for a track's own
   *  zone where that isn't known (IMPLEMENTATION.md §4.30); the client shows a time with no
   *  track of its own in it (a Spot's capture). */
  timezone: string;
  /** Miles or kilometers, as the server decides it from `country` (ADR-0048). */
  unitSystem: 'metric' | 'imperial';
  /** What `country` calls its regions and counties, for Fog's level control (webLayers.ts). */
  fogWords: { region: string; county: string };
}

export interface AuthUser extends UserProfile {
  email: string;
  /** docs/SPEC.md FR-1.8 — always `true` for a
   *  `DemoUser` (the gate never applies to one, so that type doesn't carry this field at all),
   *  reflects the account's real `users.email_verified` column for a real one. App.tsx checks
   *  this to decide whether to render the map or leave for the verify-email page. */
  emailVerified: boolean;
}

/** VISION.md §8.2's shared demo account. Its real email is an internal,
 *  never-shown placeholder the backend strips (see auth.go's handleMe/handleDemoStart), and
 *  having no `email` field at all is what lets `'email' in user` narrow a SessionUser
 *  correctly with no separate discriminant tag needed — the rest of `UserProfile` is still
 *  real, though, since a demo account is a real row with real column defaults. */
export interface DemoUser extends UserProfile {}

/** What `getCurrentUser` can resolve to: a signed-in account or the demo. */
export type SessionUser = AuthUser | DemoUser;

function toProfile(body: Schema<'Account'>): UserProfile {
  return {
    displayName: body.display_name,
    country: body.country,
    avatarUrl: body.avatar_url,
    timezone: body.timezone,
    unitSystem: body.unit_system,
    fogWords: body.fog_words,
  };
}

function toAuthUser(body: Schema<'Account'>): AuthUser {
  return { email: body.email, emailVerified: body.email_verified, ...toProfile(body) };
}

function toSessionUser(body: Schema<'Account'>): SessionUser {
  return body.isDemo ? toProfile(body) : toAuthUser(body);
}

/** Resolves to the signed-in user (real or demo), or `null` if there is no valid session —
 *  not an error: this is the normal "nobody's signed in yet" state on first load, checked
 *  deliberately rather than treated as a failure. */
export async function getCurrentUser(): Promise<SessionUser | null> {
  const res = await fetch(`${API_BASE_URL}${API_V2}/auth/me`, { credentials: 'include' });
  if (res.status === 401) return null;
  if (!res.ok) {
    throw new Error(await errorMessageFromResponse(res, t('common.request_failed', { status: res.status })));
  }
  const body = (await res.json()) as ResponseJson<'/auth/me', 'get'>;
  return toSessionUser(body);
}

/**
 * One row of IMPLEMENTATION.md §4.7's track list. `distanceMeters` and `movingSeconds`
 * are nullable because the schema is — a file that carried no distance is not a
 * zero-distance track, and the UI says "—" rather than "0.0 km".
 *
 * `name` (§4.7: a user-entered title only, never parsed from a source file) is what a row leads
 * with when set; `startedAt` is the fallback for a row that has none. `null` means never set, not
 * "set to empty." What only the Edit window needs is TrackDetail's, read per track.
 */
export interface Track {
  id: string;
  startedAt: string;
  /** The IANA zone it was recorded in (IMPLEMENTATION.md §4.30): every time of this track
   *  is shown in it, not the browser's or the account's. */
  timezone: string;
  trackType: string;
  name: string | null;
  distanceMeters: number | null;
  /** The time a row shows: moving time, the same Trips and Trends sum, else elapsed. */
  movingSeconds: number | null;
  /** [minLon, minLat, maxLon, maxLat], or null for a row with no trajectory. */
  bbox: BBox | null;
  /** An Edit route reprocess (§4.7.7) is queued or running — the row's numbers and geometry
   *  are still the pre-edit ones until it finishes. */
  pending: boolean;
  /** Entirely inside the account's Private locations (FR-7.1): kept with no track, so its
   *  distance and duration mean nothing — the row shows a Private badge instead. */
  private: boolean;
  /** The Trips it's in, newest first — the Tracks panel's Trip badge. */
  trips: { id: string; name: string }[];
}

/** A track as the Edit window needs it: the row, and what the area list leaves out
 *  (`GET /v2/tracks/{id}`). */
export interface TrackDetail extends Track {
  /** Free text (`docs/SPEC.md` FR-5.5); `null` means never set. */
  description: string | null;
  /** The track carries a user edit, so "Reset to original track" has something to undo. */
  edited: boolean;
  /** Why Edit route can't open for it (`docs/SPEC.md` FR-5.7), or null when it can. */
  routeEdit: Schema<'TrackRow'>['route_edit'] | null;
  /** Why photos can't be added to it (FR-15.1), or null when they can. */
  photos: Schema<'TrackRow'>['photos'] | null;
}

/** GeoJSON bbox ordering, which is also what MapLibre's fitBounds takes as a flat array. */
export type BBox = [number, number, number, number];

/** Filters, all optional — an absent one means "no restriction", per §4.7's convention. */
export interface TrackQuery {
  from?: string;
  to?: string;
  types?: string[];
  /** One Trip's tracks only (`SPEC.md` FR-13.4). */
  trip?: string;
  /** Tracks tiles only: tracks starting at or after this moment (`SPEC.md` FR-5.11). */
  since?: string;
}

/** The web's area list (`SPEC.md` FR-5.11): the newest tracks crossing `bbox`, 1,000 at most;
 *  without one, the newest `limit` of the whole history. */
export interface AreaQuery {
  bbox?: BBox;
  from?: string;
  to?: string;
  limit?: number;
}

function trackQueryString(query: TrackQuery): string {
  const params = new URLSearchParams();
  if (query.from) params.set('from', query.from);
  if (query.to) params.set('to', query.to);
  if (query.types?.length) params.set('types', query.types.join(','));
  if (query.trip) params.set('trip', query.trip);
  const qs = params.toString();
  return qs ? `?${qs}` : '';
}

/** A row of either list as the panel shows it; the area list's rows are slim, so this reads only
 *  what both have. */
function toTrack(a: Schema<'TrackRow'> | Schema<'AreaTrackRow'>): Track {
  return {
    id: a.id,
    startedAt: a.started_at,
    timezone: a.timezone,
    trackType: a.track_type,
    name: a.name,
    distanceMeters: a.distance_meters,
    movingSeconds: a.moving_seconds,
    bbox: a.bbox ? [...a.bbox] : null,
    pending: a.pending,
    private: a.private,
    trips: a.trips,
  };
}

function toTrackDetail(a: Schema<'TrackRow'>): TrackDetail {
  return { ...toTrack(a), description: a.description, edited: a.edited, routeEdit: a.route_edit ?? null, photos: a.photos ?? null };
}

/** A list response: the rows, and for an area how many it holds, more than the rows when they
 *  were cut at the limit; null otherwise. */
interface TrackPage {
  tracks: Track[];
  total: number | null;
}

function rememberTypes(types: Schema<'TrackTypes'>): void {
  rememberTypeLabels(Object.entries(types).map(([type, info]) => [type, info.label]));
  rememberTypeKinds(Object.entries(types).map(([type, info]) => [type, info.kind]));
}

/** [notFound] is what a `404` throws, for a caller that tells it from other failures. */
/**
 * `fetch` for one of the API's paths under /v2, with the session cookie. A 401 means the session
 * ended under the open tab: the page goes to sign-in, and the promise never settles, so no caller
 * shows the error or asks again on its way out.
 */
async function apiFetch(path: string, init: RequestInit = {}): Promise<Response> {
  const res = await fetch(`${API_BASE_URL}${API_V2}${path}`, { ...init, credentials: 'include' });
  if (res.status !== 401) return res;
  window.location.replace('/signin');
  return new Promise<Response>(() => {});
}

async function getJson<T>(path: string, signal?: AbortSignal, notFound?: () => Error): Promise<T> {
  // A conditional spread: exactOptionalPropertyTypes:true rejects `{ signal: undefined }`.
  const res = await apiFetch(path, signal ? { signal } : {});
  if (res.status === 404 && notFound) throw notFound();
  if (!res.ok) {
    throw new Error(await errorMessageFromResponse(res, t('common.request_failed', { status: res.status })));
  }
  return (await res.json()) as T;
}

/** `GET /v2/tracks/area` (`SPEC.md` FR-5.11): the web's list, and the set its map draws. */
export async function listArea(query: AreaQuery, signal?: AbortSignal): Promise<TrackPage> {
  const params = new URLSearchParams();
  if (query.bbox) params.set('bbox', query.bbox.join(','));
  if (query.from) params.set('from', query.from);
  if (query.to) params.set('to', query.to);
  if (query.limit !== undefined) params.set('limit', String(query.limit));
  const qs = params.toString();
  const body = await getJson<ResponseJson<'/tracks/area', 'get'>>(`/tracks/area${qs ? `?${qs}` : ''}`, signal);
  rememberTypes(body.types);
  return { tracks: body.tracks.map(toTrack), total: body.total ?? null };
}

/** Thrown by `getTrack` for a track that was deleted. */
export class TrackNotFoundError extends Error {}

/** `GET /v2/tracks/{id}`: one track in full, for the Edit window. */
export async function getTrack(id: string, signal?: AbortSignal): Promise<TrackDetail> {
  const path = `/tracks/${encodeURIComponent(id)}`;
  const body = await getJson<ResponseJson<'/tracks/{id}', 'get'>>(path, signal, () => new TrackNotFoundError(t('common.request_failed', { status: 404 })));
  rememberTypes(body.types);
  const row = body.tracks[0];
  if (row === undefined) throw new Error(t('common.bad_response'));
  return toTrackDetail(row);
}

/**
 * §4.7's `GET /v2/tracks`. Unpaginated: every track matching the filter comes back in
 * one response, since the Tracks panel needs the full set at once to draw the map, total
 * the stats and compute its type/distance facets.
 */
export async function listTracks(query: TrackQuery = {}, signal?: AbortSignal): Promise<TrackPage> {
  const body = await getJson<ResponseJson<'/tracks', 'get'>>(`/tracks${trackQueryString(query)}`, signal);
  rememberTypes(body.types);
  return { tracks: body.tracks.map(toTrack), total: null };
}

/**
 * `PATCH /v2/tracks/{id}` (`docs/SPEC.md` FR-5.5) — the Edit window's Save, for its Route tab's
 * fields. Full-replace-on-save, not per-field: all three fields commit together.
 * Returns the updated row so the caller can `reload()` the list (EditTrackWindow.tsx's caller does,
 * matching the "just refetch" convention an upload completion already uses) rather than
 * needing this return value directly — returned anyway: one fewer thing for a caller to
 * assume about the request.
 */
export async function updateTrack(
  id: string,
  patch: { trackType: string; name: string; description: string },
): Promise<TrackDetail> {
  const res = await apiFetch(`/tracks/${encodeURIComponent(id)}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: jsonBody<'/tracks/{id}', 'patch'>({ track_type: patch.trackType, name: patch.name, description: patch.description }),
  });
  if (!res.ok) {
    throw new Error(await errorMessageFromResponse(res, t('common.request_failed', { status: res.status })));
  }
  const body = (await res.json()) as ResponseJson<'/tracks/{id}', 'patch'>;
  return toTrackDetail(body);
}

/**
 * §4.7.5's `DELETE /v2/tracks/{id}` — a full purge (track, Fog coverage,
 * the raw upload), not a soft delete. `204 No Content` on success: nothing to parse or return.
 */
export async function deleteTrack(id: string): Promise<void> {
  const res = await apiFetch(`/tracks/${encodeURIComponent(id)}`, {
    method: 'DELETE',
  });
  if (!deleteDone(res.status)) {
    throw new Error(await errorMessageFromResponse(res, t('common.request_failed', { status: res.status })));
  }
}

/** One day of §4.7's histogram — a day that actually has tracks; days with none are absent. */
interface HistogramBucket {
  date: string;
  count: number;
  distanceMeters: number;
}

interface TrackDayPage {
  /** "day" — §4.7's resolved granularity. Present so a future weekly rollup is detectable. */
  bucket: string;
  /** The first and last day this page actually returned, or "" for an empty page. */
  from: string;
  to: string;
  /** Ascending by date, exactly `limit` entries unless the history ran out. */
  days: HistogramBucket[];
  /** This user's first track's day, or null if they have none, independent of this page's
   *  own bounds — the Dates filter's earliest (useHistoryStart.ts). */
  earliest: string | null;
}

interface DayPageQuery {
  /** How many days-with-track to return. */
  limit: number;
  /** Return the `limit` most recent days strictly before this one; omit for the newest. */
  before?: string;
}

/**
 * `GET /v2/tracks/histogram?days=&before=` — §4.7's track-day pagination mode, over the
 * whole history, never filtered. The web reads one day of it for `earliest`; the apps' date
 * sliders page through it. The endpoint's other mode (`from`/`to`, a calendar window) has no
 * reader here.
 */
export async function getTrackDayPage(query: DayPageQuery, signal?: AbortSignal): Promise<TrackDayPage> {
  const params = new URLSearchParams({ days: String(query.limit) });
  if (query.before) params.set('before', query.before);
  const res = await apiFetch(`/tracks/histogram?${params.toString()}`, {
    ...(signal ? { signal } : {}),
  });
  if (!res.ok) {
    throw new Error(await errorMessageFromResponse(res, t('common.request_failed', { status: res.status })));
  }
  const body = (await res.json()) as ResponseJson<'/tracks/histogram', 'get'>;
  return {
    bucket: body.bucket,
    from: body.from,
    to: body.to,
    days: body.buckets.map((b) => ({ date: b.date, count: b.count, distanceMeters: b.distance_meters })),
    earliest: body.earliest ?? null,
  };
}

interface RouteMetricPoint {
  lon: number;
  lat: number;
  speedMps: number;
  /** The point's moment, epoch seconds — what the Photos tab's slider saves (§4.27). */
  timeS: number;
}

/** A run of points in one pace band, slowest 0, by index into the points, `end` inclusive. */
interface PaceBand {
  band: number;
  start: number;
  end: number;
}

export interface TrackRouteMetrics {
  trackId: string;
  points: RouteMetricPoint[];
  bands: PaceBand[];
}

/** `POST /v2/tracks/stats-card`: the export's stats card as a PNG, or null when every track
 *  asked for is Pending. */
export async function getStatsCard(
  request: { trackIds: string[]; width: number; height: number; theme: 'light' | 'dark' },
  signal?: AbortSignal,
): Promise<Blob | null> {
  const res = await apiFetch(`/tracks/stats-card`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    ...(signal ? { signal } : {}),
    // IMPLEMENTATION.md §4.3.3.
    body: jsonBody<'/tracks/stats-card', 'post'>({ track_ids: request.trackIds, width: request.width, height: request.height, theme: request.theme }),
  });
  if (res.status === 204) return null;
  if (!res.ok) {
    throw new Error(await errorMessageFromResponse(res, t('common.request_failed', { status: res.status })));
  }
  return res.blob();
}

/** `GET /v2/map/imagery`: whether satellite imagery is offered now, which the server stops while
 *  the imagery plan nears its monthly limit (docs/SPEC.md FR-4.10). */
export async function getMapImagery(signal?: AbortSignal): Promise<boolean> {
  const res = await apiFetch(`/map/imagery`, {
    ...(signal ? { signal } : {}),
  });
  if (!res.ok) {
    throw new Error(await errorMessageFromResponse(res, t('common.request_failed', { status: res.status })));
  }
  return ((await res.json()) as ResponseJson<'/map/imagery', 'get'>).available;
}

/** `GET /v2/tracks/pending`: which of [ids] are still Pending (IMPLEMENTATION.md §4.2.5). */
export async function pendingTracks(ids: readonly string[], signal?: AbortSignal): Promise<string[]> {
  const res = await apiFetch(`/tracks/pending?ids=${ids.map(encodeURIComponent).join(',')}`, {
    ...(signal ? { signal } : {}),
  });
  if (!res.ok) {
    throw new Error(await errorMessageFromResponse(res, t('common.request_failed', { status: res.status })));
  }
  return ((await res.json()) as ResponseJson<'/tracks/pending', 'get'>).pending;
}

/**
 * `GET /v2/tracks/{id}/route-metrics` — per-simplified-vertex speed for one track's own
 * track, matching the exact vertex sequence its display trajectory already renders. Backs
 * MapView.tsx's pace-colored segments, shown only while exactly one track has row-click
 * focus.
 */
export async function getTrackRouteMetrics(
  trackId: string,
  signal?: AbortSignal,
): Promise<TrackRouteMetrics> {
  const res = await apiFetch(`/tracks/${encodeURIComponent(trackId)}/route-metrics`, {
    ...(signal ? { signal } : {}),
  });
  if (!res.ok) {
    throw new Error(await errorMessageFromResponse(res, t('common.request_failed', { status: res.status })));
  }
  const body = (await res.json()) as ResponseJson<'/tracks/{id}/route-metrics', 'get'>;
  return {
    trackId: body.track_id,
    points: body.points.map((p) => ({ lon: p.lon, lat: p.lat, speedMps: p.speed_mps, timeS: p.time_s })),
    bands: body.bands,
  };
}

/**
 * A route edit (§4.7.7), as the server stores it: every timestamp a point's in unix
 * milliseconds. A point survives when it's inside `keep` (inclusive; absent keeps everything),
 * outside every `remove` range (inclusive), and not in `drop`; a survivor whose timestamp is a
 * key of `move` is drawn at that [lon, lat] instead. Mirrors `ingest.RouteEdit`.
 */
export type RouteEdit = Schema<'RouteEdit'>;

/** One recorded point: [lon, lat, unix ms]. */
export type RoutePoint = [number, number, number];

interface TrackRoutePoints {
  /** Every point the track is processed from, clipped by Private locations, before the user's edit. */
  points: RoutePoint[];
  /** The edit currently applied on top of `points`, or null for an unedited track. */
  edit: RouteEdit | null;
}

/** `GET /v2/tracks/{id}/route-points` — what the route editor opens with. */
export async function getTrackRoutePoints(trackId: string, signal?: AbortSignal): Promise<TrackRoutePoints> {
  const res = await apiFetch(`/tracks/${encodeURIComponent(trackId)}/route-points`, {
    ...(signal ? { signal } : {}),
  });
  if (!res.ok) {
    throw new Error(await errorMessageFromResponse(res, t('common.request_failed', { status: res.status })));
  }
  return (await res.json()) as ResponseJson<'/tracks/{id}/route-points', 'get'>;
}

/** A split would leave one part entirely inside a Private location (`split_hides_part`,
 *  FR-5.9): nothing was saved, and saving again with `allowHidden` goes ahead. The message
 *  says what the part will be. */
export class SplitHidesPartError extends Error {}

/**
 * `POST /v2/tracks/{id}/route-edit` — the editor's Apply. Sends the complete new edit
 * (null resets to the original track), and `splitAt`, a point's unix ms, to also split the
 * track there (§4.7.8); the server marks the track — both pieces, for a split — pending
 * and reprocesses it in the background, so this resolves as soon as that's queued (`202`).
 * Throws `SplitHidesPartError` for a split the user hasn't yet agreed may hide a part.
 */
export async function saveTrackRouteEdit(
  trackId: string,
  edit: RouteEdit | null,
  splitAt: number | null = null,
  allowHidden = false,
): Promise<void> {
  const res = await apiFetch(`/tracks/${encodeURIComponent(trackId)}/route-edit`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: jsonBody<'/tracks/{id}/route-edit', 'post'>(splitAt === null ? { edit } : { edit, split_at: splitAt, ...(allowHidden ? { allow_hidden: true } : {}) }),
  });
  if (!res.ok) {
    const text = await res.text().catch(() => '');
    const { code, message } = parseErrorBody(text, t('common.request_failed', { status: res.status }));
    if (code === 'split_hides_part') throw new SplitHidesPartError(message);
    throw new Error(message);
  }
}

/** One of the account's Private locations (FR-7.1): a circle whose contents are clipped off
 *  the ends of every track at ingest. `name` is `''` when unset. */
export interface PrivateLocation {
  id: string;
  name: string;
  lon: number;
  lat: number;
  radiusM: number;
}

/** What POST and PATCH send — the whole circle, never a partial update. */
export type PrivateLocationInput = Omit<PrivateLocation, 'id'>;

function toPrivateLocation(body: Schema<'PrivateLocation'>): PrivateLocation {
  return { id: body.id, name: body.name, lon: body.lon, lat: body.lat, radiusM: body.radius_m };
}


export async function listPrivateLocations(signal?: AbortSignal): Promise<PrivateLocation[]> {
  const res = await apiFetch(`/private-locations`, {
    ...(signal ? { signal } : {}),
  });
  if (!res.ok) {
    throw new Error(await errorMessageFromResponse(res, t('common.request_failed', { status: res.status })));
  }
  return ((await res.json()) as ResponseJson<'/private-locations', 'get'>).map(toPrivateLocation);
}

/** How many of the account's tracks its Private locations hide entirely: the rows the list
 *  marks private, counted across the whole account. */
export async function hiddenTrackCount(signal?: AbortSignal): Promise<number> {
  const res = await apiFetch(`/private-locations/hidden`, {
    ...(signal ? { signal } : {}),
  });
  if (!res.ok) {
    throw new Error(await errorMessageFromResponse(res, t('common.request_failed', { status: res.status })));
  }
  return ((await res.json()) as ResponseJson<'/private-locations/hidden', 'get'>).count;
}

/**
 * Creates (no `id`) or replaces a Private location. The server marks every track the old or
 * new circle could clip as pending and reprocesses them in the background, so this resolves as
 * soon as that's queued — the Track List's Pending badges show the rest.
 */
export async function savePrivateLocation(input: PrivateLocationInput, id?: string): Promise<PrivateLocation> {
  const res = await apiFetch(`/private-locations${id ? `/${encodeURIComponent(id)}` : ''}`, {
    method: id ? 'PATCH' : 'POST',
    headers: { 'Content-Type': 'application/json' },
    // Each against its own operation, so a difference between them in the contract shows here.
    body: id
      ? jsonBody<'/private-locations/{id}', 'patch'>({ name: input.name, lon: input.lon, lat: input.lat, radius_m: input.radiusM })
      : jsonBody<'/private-locations', 'post'>({ name: input.name, lon: input.lon, lat: input.lat, radius_m: input.radiusM }),
  });
  if (!res.ok) {
    throw new Error(await errorMessageFromResponse(res, t('common.request_failed', { status: res.status })));
  }
  return toPrivateLocation((await res.json()) as Schema<'PrivateLocation'>);
}

export async function deletePrivateLocation(id: string): Promise<void> {
  const res = await apiFetch(`/private-locations/${encodeURIComponent(id)}`, { method: 'DELETE' });
  if (!deleteDone(res.status)) {
    throw new Error(await errorMessageFromResponse(res, t('common.request_failed', { status: res.status })));
  }
}

/** A Trip's joint statistics, or one track type's share of them (`SPEC.md` FR-13.1). */
export interface TripTotals {
  count: number;
  distanceMeters: number;
  movingSeconds: number;
  elapsedSeconds: number;
}

/** A hand-picked, private set of the account's tracks (`SPEC.md` FR-13). `description` is
 *  `''` when unset. */
export interface Trip {
  id: string;
  name: string;
  description: string;
  /** Who sent the copy this Trip came from (FR-13.8) — their name or email address — while the
   *  Trip it was copied from still exists; null for the account's own. */
  from: string | null;
  /** Every member, earliest track first. */
  trackIds: string[];
  stats: TripTotals & { byType: (TripTotals & { trackType: string })[] };
}

function toTripTotals(body: Omit<Schema<'Trip'>['stats'], 'by_type'>): TripTotals {
  return {
    count: body.count,
    distanceMeters: body.distance_meters,
    movingSeconds: body.moving_seconds,
    elapsedSeconds: body.elapsed_seconds,
  };
}

function toTrip(body: Schema<'Trip'>): Trip {
  return {
    id: body.id,
    name: body.name,
    description: body.description ?? '',
    from: body.from,
    trackIds: body.track_ids,
    stats: {
      ...toTripTotals(body.stats),
      byType: body.stats.by_type.map((t) => {
        rememberTypeLabels([[t.track_type, t.label]]);
        return { ...toTripTotals(t), trackType: t.track_type };
      }),
    },
  };
}


/** Thrown by `getTrip` for a Trip that doesn't exist or isn't this account's — the two are
 *  one `404` on purpose (`SPEC.md` FR-13.5). */
export class TripNotFoundError extends Error {}

/** `GET /v2/trips/{id}`. */
export async function getTrip(id: string, signal?: AbortSignal): Promise<Trip> {
  const res = await apiFetch(`/trips/${encodeURIComponent(id)}`, {
    ...(signal ? { signal } : {}),
  });
  if (res.status === 404) throw new TripNotFoundError(t('trips.not_found'));
  if (!res.ok) {
    throw new Error(await errorMessageFromResponse(res, t('common.request_failed', { status: res.status })));
  }
  return toTrip((await res.json()) as Schema<'Trip'>);
}

/** `PATCH /v2/trips/{id}` — name and description, both every time. */
export async function updateTrip(id: string, input: { name: string; description: string }): Promise<Trip> {
  const res = await apiFetch(`/trips/${encodeURIComponent(id)}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: jsonBody<'/trips/{id}', 'patch'>({ name: input.name, description: input.description }),
  });
  if (!res.ok) {
    throw new Error(await errorMessageFromResponse(res, t('common.request_failed', { status: res.status })));
  }
  return toTrip((await res.json()) as Schema<'Trip'>);
}

/** `GET /v2/trips` — every Trip of the account, newest first. */
export async function listTrips(signal?: AbortSignal): Promise<Trip[]> {
  const res = await apiFetch(`/trips`, {
    ...(signal ? { signal } : {}),
  });
  if (!res.ok) {
    throw new Error(await errorMessageFromResponse(res, t('common.request_failed', { status: res.status })));
  }
  return ((await res.json()) as ResponseJson<'/trips', 'get'>).trips.map(toTrip);
}

/** `DELETE /v2/trips/{id}` — the Trip only; its tracks stay. */
export async function deleteTrip(id: string): Promise<void> {
  const res = await apiFetch(`/trips/${encodeURIComponent(id)}`, {
    method: 'DELETE',
  });
  if (!deleteDone(res.status)) {
    throw new Error(await errorMessageFromResponse(res, t('common.request_failed', { status: res.status })));
  }
}

/** `POST /v2/trips/{id}/tracks` — puts them in the Trip; any already there stay as they are. */
export async function addTripTracks(id: string, trackIds: string[]): Promise<Trip> {
  const res = await apiFetch(`/trips/${encodeURIComponent(id)}/tracks`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: jsonBody<'/trips/{id}/tracks', 'post'>({ track_ids: trackIds }),
  });
  if (!res.ok) {
    throw new Error(await errorMessageFromResponse(res, t('common.request_failed', { status: res.status })));
  }
  return toTrip((await res.json()) as Schema<'Trip'>);
}

/** `DELETE /v2/trips/{id}/tracks` — takes them out of the Trip; the tracks stay. */
export async function removeTripTracks(id: string, trackIds: string[]): Promise<Trip> {
  const res = await apiFetch(`/trips/${encodeURIComponent(id)}/tracks`, {
    method: 'DELETE',
    headers: { 'Content-Type': 'application/json' },
    body: jsonBody<'/trips/{id}/tracks', 'delete'>({ track_ids: trackIds }),
  });
  if (!res.ok) {
    throw new Error(await errorMessageFromResponse(res, t('common.request_failed', { status: res.status })));
  }
  return toTrip((await res.json()) as Schema<'Trip'>);
}

/** `POST /v2/trips/{id}/send` — a copy of the Trip to `email` (FR-13.7). Succeeds whether or
 *  not the address has an account: the server never says. */
export async function sendTrip(id: string, email: string): Promise<void> {
  const res = await apiFetch(`/trips/${encodeURIComponent(id)}/send`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: jsonBody<'/trips/{id}/send', 'post'>({ email }),
  });
  if (!res.ok) {
    throw new Error(await errorMessageFromResponse(res, t('common.request_failed', { status: res.status })));
  }
}

/** A copy of a Trip someone sent the account, waiting to be accepted or declined (FR-13.7). */
interface TripSend {
  id: string;
  tripName: string;
  /** The sender's name, or their email address when they've set none. */
  from: string;
  trackCount: number;
}

/** A copy the account accepted that hasn't finished arriving. */
interface TripCopying {
  tripName: string;
  from: string;
}

export interface TripInbox {
  sends: TripSend[];
  copying: TripCopying[];
}

/** `GET /v2/trip-sends` — the copies waiting for the account, newest first, and the accepted
 *  ones still being copied. */
export async function listTripSends(signal?: AbortSignal): Promise<TripInbox> {
  const res = await apiFetch(`/trip-sends`, {
    ...(signal ? { signal } : {}),
  });
  if (!res.ok) {
    throw new Error(await errorMessageFromResponse(res, t('common.request_failed', { status: res.status })));
  }
  const body = (await res.json()) as ResponseJson<'/trip-sends', 'get'>;
  return {
    sends: body.sends.map((s) => ({ id: s.id, tripName: s.trip_name, from: s.from, trackCount: s.track_count })),
    copying: body.copying.map((c) => ({ tripName: c.trip_name, from: c.from })),
  };
}

/** `POST /v2/trip-sends/{id}/accept` (accept) or `DELETE /v2/trip-sends/{id}` (decline). */
export async function answerTripSend(id: string, accept: boolean): Promise<void> {
  const res = await apiFetch(`/trip-sends/${encodeURIComponent(id)}${accept ? '/accept' : ''}`, {
    method: accept ? 'POST' : 'DELETE',
  });
  // A copy its sender withdrew is gone: declining it is done, accepting it brings nothing.
  if (accept && res.status === 404) throw new Error(t('trips.inbox_withdrawn'));
  if (!deleteDone(res.status)) {
    throw new Error(await errorMessageFromResponse(res, t('common.request_failed', { status: res.status })));
  }
}

/** `POST /v2/trips` — a new Trip holding `trackIds` from the start, in one request. */
export async function createTrip(input: { name: string; description: string; trackIds: string[] }): Promise<Trip> {
  const res = await apiFetch(`/trips`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: jsonBody<'/trips', 'post'>({ name: input.name, description: input.description, track_ids: input.trackIds }),
  });
  if (!res.ok) {
    throw new Error(await errorMessageFromResponse(res, t('common.request_failed', { status: res.status })));
  }
  return toTrip((await res.json()) as Schema<'Trip'>);
}

/**
 * `GET /v2/coverage/status` — whether the account still has an unfinished job that changes its
 * Fog (an upload not yet parsed, a route edit, a re-render). Polled after an upload or delete by
 * `useCoverageRefresh.ts`, which refetches Fog once this reports nothing left.
 */
export type CoverageStatus = ResponseJson<'/coverage/status', 'get'>;

export async function getCoverageStatus(signal?: AbortSignal): Promise<CoverageStatus> {
  const res = await apiFetch(`/coverage/status`, {
    ...(signal ? { signal } : {}),
  });
  if (!res.ok) {
    throw new Error(await errorMessageFromResponse(res, t('common.request_failed', { status: res.status })));
  }
  return (await res.json()) as ResponseJson<'/coverage/status', 'get'>;
}

/** `GET /v2/spots` — "Show in this area" (FR-14.4): the places in a box, in the chosen
 *  categories. `total` is how many the box holds; more than `spots.length` when the server cut
 *  the answer at its limit. */
interface SpotsInArea {
  spots: SpotInArea[];
  total: number;
}

export async function getSpotsInArea(
  bbox: [west: number, south: number, east: number, north: number],
  categories: readonly SpotCategory[],
  signal?: AbortSignal,
): Promise<SpotsInArea> {
  const params = new URLSearchParams({ bbox: bbox.map((v) => v.toFixed(5)).join(','), categories: categories.join(',') });
  const res = await apiFetch(`/spots?${params}`, {
    ...(signal ? { signal } : {}),
  });
  if (!res.ok) {
    throw new Error(await errorMessageFromResponse(res, t('common.request_failed', { status: res.status })));
  }
  return (await res.json()) as ResponseJson<'/spots', 'get'>;
}

/** One place the account has captured with the Android app (FR-14.6). */
export type SpotCapture = Schema<'SpotCapture'>;

/** `GET /v2/spots/captures` — the account's captured places, newest first; with [since] (a
 *  `captured_at` as the server wrote it), only those captured at or after it. */
export async function getSpotCaptures(signal?: AbortSignal, since?: string): Promise<SpotCapture[]> {
  const query = since ? `?since=${encodeURIComponent(since)}` : '';
  const res = await apiFetch(`/spots/captures${query}`, {
    ...(signal ? { signal } : {}),
  });
  if (!res.ok) {
    throw new Error(await errorMessageFromResponse(res, t('common.request_failed', { status: res.status })));
  }
  return ((await res.json()) as ResponseJson<'/spots/captures', 'get'>).captures;
}

/** One photo on a track (FR-15), always with a place on its track (`routeAt`, a moment on
 *  it). `lon`/`lat` are null only for a track with no route left at all. `url` and
 *  `thumbUrl` are API paths (`/v2/photos/…`) — callers prefix `API_BASE_URL`. */
export interface Photo {
  id: string;
  trackId: string;
  takenAt: string | null;
  routeAt: string;
  /** Its track's zone, which `takenAt` and `routeAt` are shown in. */
  timezone: string;
  lon: number | null;
  lat: number | null;
  caption: string | null;
  width: number;
  height: number;
  url: string;
  thumbUrl: string;
}

function toPhoto(b: Schema<'Photo'>): Photo {
  return {
    id: b.id,
    trackId: b.track_id,
    takenAt: b.taken_at,
    routeAt: b.route_at,
    timezone: b.timezone,
    lon: b.lon,
    lat: b.lat,
    caption: b.caption,
    width: b.width,
    height: b.height,
    url: b.url,
    thumbUrl: b.thumb_url,
  };
}

/** `GET /v2/photos` — one track's photos, or every photo in a Trip; placed ones in route
 *  order, then unplaced ones. */
export async function listPhotos(of: { track: string } | { trip: string }, signal?: AbortSignal): Promise<Photo[]> {
  const params = new URLSearchParams('track' in of ? { track: of.track } : { trip: of.trip });
  const res = await apiFetch(`/photos?${params}`, {
    ...(signal ? { signal } : {}),
  });
  if (!res.ok) {
    throw new Error(await errorMessageFromResponse(res, t('common.request_failed', { status: res.status })));
  }
  return ((await res.json()) as ResponseJson<'/photos', 'get'>).photos.map(toPhoto);
}

/** The server couldn't tell where on the track a photo was taken (`photo_needs_place`, FR-15.1):
 *  nothing was stored, and it goes again with the user's `routeAt`. */
export class PhotoNeedsPlaceError extends Error {}

/** What a photo's EXIF said, as the placement fields `POST /v2/photos` and its check take. */
interface PhotoExifFields {
  takenAt?: string;
  takenLocal?: string;
  lat?: number;
  lon?: number;
}

/** `POST /v2/photos/place` — where an upload of a photo with this EXIF would be placed (`routeAt`,
 *  RFC 3339), storing nothing; `PhotoNeedsPlaceError` when the server can't tell. */
export async function checkPhotoPlace(trackId: string, exif: PhotoExifFields): Promise<{ routeAt: string }> {
  const res = await apiFetch(`/photos/place`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: jsonBody<'/photos/place', 'post'>({ track_id: trackId, taken_at: exif.takenAt, taken_local: exif.takenLocal, lat: exif.lat, lon: exif.lon }),
  });
  if (!res.ok) {
    const text = await res.text().catch(() => '');
    const { code, message } = parseErrorBody(text, t('common.request_failed', { status: res.status }));
    if (code === 'photo_needs_place') throw new PhotoNeedsPlaceError(message);
    throw new Error(message);
  }
  return { routeAt: ((await res.json()) as ResponseJson<'/photos/place', 'post'>).route_at };
}

/** `POST /v2/photos` — a photo already resized by `photoPrep.ts`, with what its EXIF said, where
 *  on the track it goes (`routeAt`, RFC 3339 — the placement check's answer or the user's), and
 *  its caption. */
export async function uploadPhoto(
  trackId: string,
  photo: { file: Blob; thumb: Blob; exif: PhotoExifFields },
  routeAt?: string,
  caption?: string,
): Promise<Photo> {
  const form = new FormData();
  form.set('track_id', trackId);
  form.set('file', photo.file, 'photo');
  form.set('thumb', photo.thumb, 'thumb');
  const { takenAt, takenLocal, lat, lon } = photo.exif;
  if (takenAt) form.set('taken_at', takenAt);
  else if (takenLocal) form.set('taken_local', takenLocal);
  if (lat !== undefined && lon !== undefined) {
    form.set('lat', String(lat));
    form.set('lon', String(lon));
  }
  if (routeAt) form.set('route_at', routeAt);
  if (caption) form.set('caption', caption);
  const res = await apiFetch('/photos', { method: 'POST', body: form });
  if (!res.ok) {
    const text = await res.text().catch(() => '');
    const { code, message } = parseErrorBody(text, t('common.request_failed', { status: res.status }));
    if (code === 'photo_needs_place') throw new PhotoNeedsPlaceError(message);
    throw new Error(message);
  }
  return toPhoto((await res.json()) as Schema<'Photo'>);
}

/** `PATCH /v2/photos/{id}` — a field present changes. `routeAt` (RFC 3339) is the photo's new
 *  moment on its track; the server clamps it to the track. */
export async function updatePhoto(id: string, change: { caption?: string | undefined; routeAt?: string | undefined }): Promise<Photo> {
  const res = await apiFetch(`/photos/${encodeURIComponent(id)}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: jsonBody<'/photos/{id}', 'patch'>({ caption: change.caption, route_at: change.routeAt }),
  });
  if (!res.ok) {
    throw new Error(await errorMessageFromResponse(res, t('common.request_failed', { status: res.status })));
  }
  return toPhoto((await res.json()) as Schema<'Photo'>);
}

/** `DELETE /v2/photos/{id}`. */
export async function deletePhoto(id: string): Promise<void> {
  const res = await apiFetch(`/photos/${encodeURIComponent(id)}`, { method: 'DELETE' });
  if (!deleteDone(res.status)) {
    throw new Error(await errorMessageFromResponse(res, t('common.request_failed', { status: res.status })));
  }
}
