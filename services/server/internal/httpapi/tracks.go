package httpapi

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"

	"github.com/HoldMyTrack/platform/services/server/internal/fog"
	"github.com/HoldMyTrack/platform/services/server/internal/ingest"
)

// trackFilter is the from/to/types/story filter shape shared by §4.3's tracks tiles and
// all three of §4.7's listing endpoints. Every field is optional and a nil field means "no
// restriction" — the convention both sections specify, so a caller that wants everything
// sends nothing rather than an explicit wide-open range.
type trackFilter struct {
	// From and To are local dates (YYYY-MM-DD), both inclusive, matched against each
	// track's own local date (localStartedAt).
	From  *string
	To    *string
	Types []string
	// Trip narrows to one Trip's tracks (§4.23). No ownership check is needed: the
	// queries are already scoped to the caller's own tracks, and a Trip only ever holds
	// its owner's, so another account's Trip matches nothing — the same as an empty one.
	Trip *string
}

// parseTrackFilter reads that filter off a query string. A `from`/`to` date is a local
// date, matched against each track's own (IMPLEMENTATION.md §4.30): `?from=2026-03-10`
// means "the 10th where each track happened," so a run at 07:00 in Tokyo is on the 10th
// whatever the account's or the browser's zone. The returned error is already phrased for the
// client; callers pass it straight to http.Error with a 400.
func parseTrackFilter(q url.Values) (trackFilter, error) {
	var f trackFilter
	if v := q.Get("from"); v != "" {
		if _, err := time.Parse(dateLayout, v); err != nil {
			return trackFilter{}, errors.New(`invalid "from" date, want YYYY-MM-DD`)
		}
		f.From = &v
	}
	if v := q.Get("to"); v != "" {
		if _, err := time.Parse(dateLayout, v); err != nil {
			return trackFilter{}, errors.New(`invalid "to" date, want YYYY-MM-DD`)
		}
		f.To = &v
	}
	// nil, not an empty non-nil slice, when the param is absent — pgx sends a nil []string
	// as SQL NULL, which is what the "$n::text[] IS NULL OR ..." clauses check for.
	if v := q.Get("types"); v != "" {
		f.Types = strings.Split(v, ",")
	}
	trip, err := parseTripParam(q)
	if err != nil {
		return trackFilter{}, err
	}
	f.Trip = trip
	return f, nil
}

// trackBBoxColumns is a track's bbox as four columns, west, south, east, north, the
// shorter way round in longitude. A track across the antimeridian is stored continuing past
// ±180 (§4.1), so its plain bbox already is (179.9…180.1, east past 180, the form MapLibre
// fits as it is). One stored jumping back across the world, before that and with no raw
// payload to reprocess it from, spans −179.9…179.9; it's read off ST_ShiftLongitude's copy
// instead, which moves the western hemisphere's points past 180. The shifted copy is only
// made for a box over 180° wide, which no other track has.
var trackBBoxColumns = shorterWay("ST_XMin") + `, ST_YMin(trajectory), ` + shorterWay("ST_XMax") + `, ST_YMax(trajectory)`

func shorterWay(edge string) string {
	plainWidth := `ST_XMax(trajectory) - ST_XMin(trajectory)`
	shiftedWidth := `ST_XMax(ST_ShiftLongitude(trajectory)) - ST_XMin(ST_ShiftLongitude(trajectory))`
	return `CASE WHEN ` + plainWidth + ` > 180 THEN
           CASE WHEN ` + shiftedWidth + ` < ` + plainWidth + ` THEN ` + edge + `(ST_ShiftLongitude(trajectory)) ELSE ` + edge + `(trajectory) END
         ELSE ` + edge + `(trajectory) END`
}

// localStartedAt is a track's start as the wall clock read where it was recorded: every
// day, week or month a track is grouped or filtered by is this one's (§4.30). The zone is
// a name, so the tz database gives the offset in force on that date.
const localStartedAt = `(started_at AT TIME ZONE timezone)`

// inDateRange is the optional from/to clause on localStartedAt, both ends inclusive local
// dates (from and to name ::date parameters, NULL for no limit).
func inDateRange(from, to string) string {
	return `(` + from + `::date IS NULL OR ` + localStartedAt + ` >= ` + from + `::date)
  AND (` + to + `::date IS NULL OR ` + localStartedAt + ` < ` + to + `::date + 1)`
}

// sqlDate is t's calendar date in its own location, as a ::date parameter takes it.
func sqlDate(t time.Time) string { return t.Format(dateLayout) }

// parseTripParam reads the optional `trip` Trip id, nil when absent.
func parseTripParam(q url.Values) (*string, error) {
	v := q.Get("trip")
	if v == "" {
		return nil, nil
	}
	if !uuidPattern.MatchString(v) {
		return nil, errors.New(`invalid "trip", want a Trip id`)
	}
	return &v, nil
}

// trackTripsColumn is the Trips a track is in (§4.23), newest first, as a JSON array
// of {id, name} — one indexed lookup per row (idx_story_activities_activity). A Trip only ever
// holds its owner's tracks, so it needs no user filter of its own.
const trackTripsColumn = `COALESCE((
         SELECT json_agg(json_build_object('id', s.id, 'name', s.name) ORDER BY s.created_at DESC, s.id DESC)
         FROM trip_tracks sa JOIN trips s ON s.id = sa.trip_id
         WHERE sa.track_id = tracks.id), '[]'::json)`

// maxTrackTypeLen matches tracks.track_type's own VARCHAR(50) — rejecting an
// over-length value here is a clearer 400 than letting Postgres reject the UPDATE. These limits
// count characters (runes), as VARCHAR and SPEC FR-5.5 do, not bytes: a Cyrillic name takes
// two bytes a letter.
const maxTrackTypeLen = 50

// maxTrackDescriptionLen is a generous free-text bound (about the length of a couple of
// paragraphs), not a claim that anyone needs that much — the same "reject an obvious mistake,
// not opine on reasonable length" reasoning.
const maxTrackDescriptionLen = 2000

// maxTrackNameLen matches tracks.name's varchar(200): a single-line title, shorter than
// maxTrackDescriptionLen, since anything longer belongs in the description.
const maxTrackNameLen = 200

// trackByIDQuery is the single-row counterpart to listTracksQuery, same column order
// (scanTrackRow's Scan call is shared between both), scoped by id and owner exactly like
// routeMetricsQuery — a non-owned or nonexistent id is indistinguishable from "not found."
var trackByIDQuery = `
SELECT id, started_at, timezone, track_type, name, distance_meters, duration_seconds,
       COALESCE(moving_seconds, duration_seconds), description,
       ` + trackBBoxColumns + `,
       edit_pending, route_edit IS NOT NULL, trajectory IS NULL, raw_payload_key IS NOT NULL, editable_times,
       split_group, split_from, split_to,
       ` + trackTripsColumn + `
FROM tracks
WHERE id = $1 AND user_id = $2`

type updateTrackRequest struct {
	TrackType   string `json:"track_type"`
	Name        string `json:"name"`
	Description string `json:"description"`
}

// trackIDFromPath is the {id} of an /tracks/…/{id} route, lowercased, or a 404 for one
// that isn't a UUID. Postgres refuses a malformed uuid with an error, which reached the client
// as a 500; and it accepts an uppercase one, which would then miss object keys built from the
// id (the delete's mask prefix) while still matching the row.
func trackIDFromPath(w http.ResponseWriter, r *http.Request) (string, bool) {
	id := r.PathValue("id")
	if !uuidPattern.MatchString(id) {
		writeAPIError(w, "track not found", http.StatusNotFound)
		return "", false
	}
	return strings.ToLower(id), true
}

// handleUpdateTrack serves `PATCH /v2/tracks/{id}` (docs/SPEC.md FR-5.5) — the "rename a
// mis-tagged upload" / "describe a non-sport GPS trace" feature. track_type is free-form
// (IMPLEMENTATION.md §4.7), not a controlled vocabulary, so a manual rename here is
// architecturally identical to what ingest itself already writes — nothing to validate
// against an allow-list, just a length bound matching the column.
//
// Full-replace-on-save, not per-field PATCH semantics, matching account.go's
// handleUpdateSettings: one Save button in the edit dialog commits all three fields at once.
// Empty name/description means "clear it," written as NULLIF the same way every other
// optional text column here already is; track_type has no such escape hatch since the
// column is NOT NULL — an empty value is rejected outright rather than silently kept
// unchanged.
func (s *Server) handleUpdateTrack(w http.ResponseWriter, r *http.Request) {
	trackID, ok := trackIDFromPath(w, r)
	if !ok {
		return
	}
	userID := userIDFromContext(r.Context())

	var req updateTrackRequest
	if err := decodeJSON(r.Body, &req); err != nil {
		writeAPIError(w, bodyError(err, "invalid request body"), http.StatusBadRequest)
		return
	}
	req.TrackType = strings.TrimSpace(req.TrackType)
	req.Name = strings.TrimSpace(req.Name)
	req.Description = strings.TrimSpace(req.Description)
	if req.TrackType == "" {
		httpErrorT(w, r, http.StatusBadRequest, "error.track_type_required")
		return
	}
	if utf8.RuneCountInString(req.TrackType) > maxTrackTypeLen {
		httpErrorT(w, r, http.StatusBadRequest, "error.track_type_too_long", "max", maxTrackTypeLen)
		return
	}
	if utf8.RuneCountInString(req.Name) > maxTrackNameLen {
		httpErrorT(w, r, http.StatusBadRequest, "error.track_name_too_long", "max", maxTrackNameLen)
		return
	}
	if utf8.RuneCountInString(req.Description) > maxTrackDescriptionLen {
		httpErrorT(w, r, http.StatusBadRequest, "error.track_description_too_long", "max", maxTrackDescriptionLen)
		return
	}

	ctx := r.Context()
	tag, err := s.pool.Exec(ctx, `
		UPDATE tracks SET track_type = $3, name = NULLIF($4, ''), description = NULLIF($5, '')
		WHERE id = $1 AND user_id = $2
	`, trackID, userID, req.TrackType, req.Name, req.Description)
	if err != nil {
		s.log.Error("activity update failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	if tag.RowsAffected() == 0 {
		writeAPIError(w, "track not found", http.StatusNotFound)
		return
	}
	// track_type is in every tracks tile this track crosses, and no render follows.
	if err := fog.BumpMapVersion(ctx, s.pool, userID); err != nil {
		s.log.Error("activity update: bump map version failed", "activity_id", trackID, "err", err)
	}

	row, err := scanTrackRow(s.pool.QueryRow(ctx, trackByIDQuery, trackID, userID))
	if err != nil {
		s.log.Error("activity lookup after update failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, row)
}

// handleDeleteTrack serves `DELETE /v2/tracks/{id}` (§4.7.5) — a full purge, not a
// soft delete: the DB cascade already handles track_tile_masks and their mask data
// (`ON DELETE CASCADE` back to tracks.id), and Trends is live-aggregated over whatever
// rows remain, so neither needs any explicit cleanup here. Two things do:
//
//   - Object storage has no foreign keys, so the raw upload has to be removed explicitly,
//     unless another track (a split piece, a re-import) still names it.
//   - Fog reads a precomputed per-user, per-tile cache that ingest builds by
//     compositing track_tile_masks rows together, but only ingest ever marks a tile dirty
//     or enqueues its re-render — deleting a track would otherwise cascade its masks away
//     while leaving that cache's already-rendered PNGs stale indefinitely, still showing
//     coverage for a track that no longer exists.
//
// Runs synchronously in the handler, like handleUpdateTrack/handleDeleteAvatar: unlike
// ingest's parsing, everything here (a row delete, a couple of small queries, an
// object-storage prefix removal) is cheap enough not to need the job queue itself — only the
// actual tile re-render at the end goes through it, the same render_fog job ingest already
// relies on.
func (s *Server) handleDeleteTrack(w http.ResponseWriter, r *http.Request) {
	trackID, ok := trackIDFromPath(w, r)
	if !ok {
		return
	}
	userID := userIDFromContext(r.Context())
	ctx := r.Context()

	// Read back what the cascade is about to delete out from under us — both are needed only
	// for cleanup below, and both would be gone (or unrecoverable) once the DELETE runs.
	var rawKey *string
	if err := s.pool.QueryRow(ctx,
		`SELECT raw_payload_key FROM tracks WHERE id = $1 AND user_id = $2`, trackID, userID,
	).Scan(&rawKey); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			writeAPIError(w, "track not found", http.StatusNotFound)
			return
		}
		s.log.Error("activity lookup before delete failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}

	tiles, err := ingest.TrackTiles(ctx, s.pool, trackID)
	if err != nil {
		s.log.Error("activity tile lookup before delete failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}

	// The track's photos (§4.27) go with it; the cascade takes their rows, so their images
	// have to be removed explicitly — after the rows, since a copied Trip's photo (§4.23) can
	// share them and keeps them.
	photoKeys, err := s.trackPhotoKeys(ctx, trackID)
	if err != nil {
		s.log.Error("activity delete: photo lookup failed, deleting row anyway", "activity_id", trackID, "err", err)
	}
	tag, err := s.pool.Exec(ctx, `DELETE FROM tracks WHERE id = $1 AND user_id = $2`, trackID, userID)
	if err != nil {
		s.log.Error("activity delete failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	if tag.RowsAffected() == 0 {
		writeAPIError(w, "track not found", http.StatusNotFound)
		return
	}
	if rawKey != nil {
		s.removeUnreferencedRaw(ctx, userID, trackID, *rawKey)
	}
	s.removeUnreferencedPhotoFiles(ctx, photoKeys)
	// The track is gone from the tracks tiles now; the render below only bumps once it runs.
	if err := fog.BumpMapVersion(ctx, s.pool, userID); err != nil {
		s.log.Error("activity delete: bump map version failed", "activity_id", trackID, "err", err)
	}

	// The deleted track's tiles are marked dirty and rendered again, as ingest does: a render
	// recomposites each tile from the track_tile_masks rows left, which no longer include
	// this track's.
	if len(tiles) > 0 {
		if err := ingest.MarkFogTilesDirty(ctx, s.pool, userID, tiles); err != nil {
			s.log.Error("activity delete: mark fog tiles dirty failed", "activity_id", trackID, "err", err)
		} else if err := ingest.EnqueueRenderFog(ctx, s.pool, userID); err != nil {
			s.log.Error("activity delete: enqueue render_fog failed", "activity_id", trackID, "err", err)
		}
	}

	w.WriteHeader(http.StatusNoContent)
}

// routeMetricsQuery reads one track's already-simplified display trajectory back out
// (ST_DumpPoints, same shape simplifyXY already produces at ingest — this just reads it
// instead of simplifying fresh). The M ordinate is epoch seconds per §3.3, which is all a
// per-vertex speed needs besides position.
const routeMetricsQuery = `
SELECT array_agg(ST_X(pt.geom) ORDER BY pt.path),
       array_agg(ST_Y(pt.geom) ORDER BY pt.path),
       array_agg(ST_M(pt.geom) ORDER BY pt.path),
       a.route_edit
FROM tracks a
CROSS JOIN LATERAL ST_DumpPoints(a.trajectory) AS pt
WHERE a.id = $1 AND a.user_id = $2
GROUP BY a.id`

type routeMetricPoint struct {
	Lon      float64 `json:"lon"`
	Lat      float64 `json:"lat"`
	SpeedMps float64 `json:"speed_mps"`
	// TimeS is the point's moment, epoch seconds — what the Edit window's photo slider (§4.27)
	// turns a place on the track into.
	TimeS int64 `json:"time_s"`
}

type routeMetricsResponse struct {
	TrackID string             `json:"track_id"`
	Points  []routeMetricPoint `json:"points"`
	Bands   []paceBand         `json:"bands"`
}

// pointSpeeds is each point's speed from the one before it, in m/s: 0 across no time, and the
// first point takes the second's. ms is the M ordinate, epoch seconds, read in whole seconds. A
// Cut's join has no pace of its own, so it keeps the speed before it, or after it at the start.
func pointSpeeds(lons, lats, ms []float64, edit *ingest.RouteEdit) []float64 {
	n := len(lons)
	speed := make([]float64, n)
	leadingJoins := 0
	for i := 1; i < n; i++ {
		// Whole seconds either way, so a range ending within the second still falls inside.
		from, to := int64(ms[i-1]), int64(ms[i])
		if edit.JoinsCut(from*1000, to*1000+999) {
			if i-1 == leadingJoins {
				leadingJoins = i
			} else {
				speed[i] = speed[i-1]
			}
			continue
		}
		if dt := float64(to - from); dt > 0 {
			speed[i] = ingest.HaversineM(lats[i-1], lons[i-1], lats[i], lons[i]) / dt
		}
	}
	if leadingJoins+1 < n {
		for i := leadingJoins; i >= 1; i-- {
			speed[i] = speed[leadingJoins+1]
		}
	}
	if n > 1 {
		speed[0] = speed[1]
	}
	return speed
}

// handleTrackRouteMetrics serves `GET /v2/tracks/{id}/route-metrics` — per-simplified-
// vertex speed, and the pace bands (paceBands) the web and Android clients draw over whichever
// single track is selected. Pace only: HoldMyTrack keeps no heart rate (VISION.md §1.1).
// Scoped to the caller's user_id in the query itself, same as every other per-track lookup
// here: a non-owned or nonexistent id is indistinguishable from "not found," nothing new to
// invent.
func (s *Server) handleTrackRouteMetrics(w http.ResponseWriter, r *http.Request) {
	trackID, ok := trackIDFromPath(w, r)
	if !ok {
		return
	}

	var lons, lats, ms []float64
	var edit *ingest.RouteEdit
	err := s.pool.QueryRow(r.Context(), routeMetricsQuery, trackID, userIDFromContext(r.Context())).
		Scan(&lons, &lats, &ms, &edit)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			writeAPIError(w, "track not found", http.StatusNotFound)
			return
		}
		if clientGone(w, r) {
			return
		}
		s.log.Error("track metrics query failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}

	speed := pointSpeeds(lons, lats, ms, edit)
	points := make([]routeMetricPoint, len(lons))
	for i := range points {
		points[i] = routeMetricPoint{Lon: lons[i], Lat: lats[i], SpeedMps: speed[i], TimeS: int64(ms[i])}
	}

	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, routeMetricsResponse{TrackID: trackID, Points: points, Bands: paceBands(speed)})
}

// removeUnreferencedRaw removes a deleted track's original once nothing else names it. Run
// after the row is gone, never before: a failed DELETE would otherwise leave a track without
// its original, and of two pieces deleted together each would see the other and both keep it.
func (s *Server) removeUnreferencedRaw(ctx context.Context, userID, trackID, rawKey string) {
	named, err := ingest.RawNamed(ctx, s.pool, userID, rawKey, 0)
	if err != nil {
		s.log.Error("activity delete: raw key reference check failed, keeping the original", "activity_id", trackID, "err", err)
		return
	}
	if named {
		return
	}
	if err := s.store.Remove(ctx, rawKey); err != nil {
		s.log.Error("activity delete: raw payload cleanup failed", "activity_id", trackID, "err", err)
	}
}
