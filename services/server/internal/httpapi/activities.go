package httpapi

import (
	"errors"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/HoldMyTrack/platform/services/server/internal/fog"
	"github.com/HoldMyTrack/platform/services/server/internal/ingest"

	"github.com/HoldMyTrack/platform/services/server/internal/activitytype"
)

// activityFilter is the from/to/types/story filter shape shared by §4.3's tracks tiles and
// all three of §4.7's listing endpoints. Every field is optional and a nil field means "no
// restriction" — the convention both sections specify, so a caller that wants everything
// sends nothing rather than an explicit wide-open range.
type activityFilter struct {
	// From and To are local dates (YYYY-MM-DD), both inclusive, matched against each
	// activity's own local date (localStartedAt).
	From  *string
	To    *string
	Types []string
	// Story narrows to one Story's activities (§4.23). No ownership check is needed: the
	// queries are already scoped to the caller's own activities, and a Story only ever holds
	// its owner's, so another account's Story matches nothing — the same as an empty one.
	Story *string
}

// parseActivityFilter reads that filter off a query string. A `from`/`to` date is a local
// date, matched against each activity's own (IMPLEMENTATION.md §4.30): `?from=2026-03-10`
// means "the 10th where each activity happened," so a run at 07:00 in Tokyo is on the 10th
// whatever the account's or the browser's zone. The returned error is already phrased for the
// client; callers pass it straight to http.Error with a 400.
func parseActivityFilter(q url.Values) (activityFilter, error) {
	var f activityFilter
	if v := q.Get("from"); v != "" {
		if _, err := time.Parse(dateLayout, v); err != nil {
			return activityFilter{}, errors.New(`invalid "from" date, want YYYY-MM-DD`)
		}
		f.From = &v
	}
	if v := q.Get("to"); v != "" {
		if _, err := time.Parse(dateLayout, v); err != nil {
			return activityFilter{}, errors.New(`invalid "to" date, want YYYY-MM-DD`)
		}
		f.To = &v
	}
	// nil, not an empty non-nil slice, when the param is absent — pgx sends a nil []string
	// as SQL NULL, which is what the "$n::text[] IS NULL OR ..." clauses check for.
	if v := q.Get("types"); v != "" {
		f.Types = strings.Split(v, ",")
	}
	story, err := parseStoryParam(q)
	if err != nil {
		return activityFilter{}, err
	}
	f.Story = story
	return f, nil
}

// activityBBoxColumns is an activity's bbox as four columns, west, south, east, north, the
// shorter way round in longitude. A track across the antimeridian is stored continuing past
// ±180 (§4.1), so its plain bbox already is (179.9…180.1, east past 180, the form MapLibre
// fits as it is). One stored jumping back across the world, before that and with no raw
// payload to reprocess it from, spans −179.9…179.9; it's read off ST_ShiftLongitude's copy
// instead, which moves the western hemisphere's points past 180. The shifted copy is only
// made for a box over 180° wide, which no other track has.
var activityBBoxColumns = shorterWay("ST_XMin") + `, ST_YMin(trajectory), ` + shorterWay("ST_XMax") + `, ST_YMax(trajectory)`

func shorterWay(edge string) string {
	plainWidth := `ST_XMax(trajectory) - ST_XMin(trajectory)`
	shiftedWidth := `ST_XMax(ST_ShiftLongitude(trajectory)) - ST_XMin(ST_ShiftLongitude(trajectory))`
	return `CASE WHEN ` + plainWidth + ` > 180 THEN
           CASE WHEN ` + shiftedWidth + ` < ` + plainWidth + ` THEN ` + edge + `(ST_ShiftLongitude(trajectory)) ELSE ` + edge + `(trajectory) END
         ELSE ` + edge + `(trajectory) END`
}

// localStartedAt is an activity's start as the wall clock read where it was recorded: every
// day, week or month an activity is grouped or filtered by is this one's (§4.30). The zone is
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

// parseStoryParam reads the optional `story` Story id, nil when absent.
func parseStoryParam(q url.Values) (*string, error) {
	v := q.Get("story")
	if v == "" {
		return nil, nil
	}
	if !uuidPattern.MatchString(v) {
		return nil, errors.New(`invalid "story", want a Story id`)
	}
	return &v, nil
}

// activityStoriesColumn is the Stories an activity is in (§4.23), newest first, as a JSON array
// of {id, name} — one indexed lookup per row (idx_story_activities_activity). A Story only ever
// holds its owner's activities, so it needs no user filter of its own.
const activityStoriesColumn = `COALESCE((
         SELECT json_agg(json_build_object('id', s.id, 'name', s.name) ORDER BY s.created_at DESC, s.id DESC)
         FROM story_activities sa JOIN stories s ON s.id = sa.story_id
         WHERE sa.activity_id = activities.id), '[]'::json)`

// listActivitiesQuery is §4.7's list, with §4.3's "$n IS NULL OR ..." optional-filter
// treatment. No pagination: the client that used to page through this (ActivitiesPanel)
// renders every matching row on the map and computes stats and type/distance facets across
// all of them at once, so a partial page was never actually usable — a caller wanting page
// 2 always had to have fetched page 1 first anyway. An account's activity count
// is in the hundreds to low thousands; revisit if that stops holding.
//
// The four ST_*Min/Max calls are the row's bounding box, so a client can fly the map to an
// activity without a follow-up request per row. They are cheaper than they look: PostGIS
// caches a geometry's bounding box in its header, so this reads that rather than walking
// the vertices. §3.3 deliberately has no bbox column and doesn't need one back — the note
// there about the removed BOX2D column applies just as well to adding a new one.
//
// Column order here has to match scanActivityRow's Scan call exactly — activityByIDQuery
// below shares that same order for the same reason.
var listActivitiesQuery = `
SELECT id, started_at, timezone, activity_type, name, distance_meters, duration_seconds, description,
       ` + activityBBoxColumns + `,
       edit_pending, track_edit IS NOT NULL, trajectory IS NULL, raw_payload_key IS NOT NULL, editable_times,
       split_group, split_from, split_to,
       ` + activityStoriesColumn + `
FROM activities
WHERE user_id = $1
  AND ` + inDateRange("$2", "$3") + `
  AND ($4::text[] IS NULL OR activity_type = ANY($4))
  AND ($5::uuid IS NULL OR activities.id IN (SELECT activity_id FROM story_activities WHERE story_id = $5))
ORDER BY started_at DESC, id DESC`

// activityRow is one row of the list. The field set is exactly what the Activities panel
// renders, no more. Duration is `duration_seconds`, not `moving_seconds`. ingest.Process
// populates moving_seconds now (added for Trends, docs/SPEC.md FR-9), but only for activities
// ingested since — anything older still has it NULL, and serving a field that's populated
// for some rows and not others in the one list every activity shares would read as broken
// data rather than as what it is. duration_seconds has no such gap.
//
// Name (migrations/0002_activities.sql) is a user-entered title, nullable — a row with
// none has never had one set, and the client falls back to started_at for its primary line
// (§4.7 revised its earlier "no name column" decision to add exactly this, and nothing
// more: still no parser reads a name out of a source file). Description (docs/SPEC.md FR-5.10,
// migrations/0002_activities.sql's activities.description) stays separate free-text, shown only
// as a hover tooltip — a row with nothing written there has never been edited, not "an
// empty description."
//
// The three metric fields are nullable in §3.3 and stay nullable here rather than being
// coerced to 0: a file that carried no distance is not a zero-distance activity.
type activityRow struct {
	ID        string    `json:"id"`
	StartedAt time.Time `json:"started_at"`
	// Timezone is the IANA zone it was recorded in (§4.30): a client shows StartedAt, and any
	// other time of this activity's, in it.
	Timezone        string   `json:"timezone"`
	ActivityType    string   `json:"activity_type"`
	Name            *string  `json:"name"`
	DistanceMeters  *float64 `json:"distance_meters"`
	DurationSeconds *int32   `json:"duration_seconds"`
	Description     *string  `json:"description"`
	// [minLon, minLat, maxLon, maxLat] — GeoJSON's bbox ordering — or null when the row has
	// no geometry. §3.3 allows a null trajectory, and a client must not fly the map nowhere.
	BBox []float64 `json:"bbox"`
	// Pending is true while an Edit track reprocess (§4.7.7) is queued or running — the row's
	// numbers and geometry are still the pre-edit ones. Edited is true once the track carries
	// a user edit, which is what makes "Reset to original track" meaningful.
	Pending bool `json:"pending"`
	Edited  bool `json:"edited"`
	// Private is an activity entirely inside the account's Private locations (FR-8.1): kept,
	// with no track, so no distance or duration worth showing — the panel badges it instead.
	// A NULL trajectory has no other cause (§3.3).
	Private bool `json:"private"`
	// TrackEdit and Photos say why the Edit window's Track or Photos tab can't be used for this
	// activity (activity_availability.go), omitted when it can.
	TrackEdit string `json:"track_edit,omitempty"`
	Photos    string `json:"photos,omitempty"`
	// Split is set on a piece of a split activity (§4.7.8): which split, and the stretch of the
	// recording it covers — what the Activities panel's Merge checks a group against.
	Split *splitRef `json:"split"`
	// Stories are the Stories it's in, newest first — the Activities panel's Story badge.
	Stories []storyRef `json:"stories"`
}

// splitRef places a piece within its split: From and To are unix-ms point timestamps, null
// at the recording's own ends. Pieces meet where one's To is the next one's From.
type splitRef struct {
	Group string `json:"group"`
	From  *int64 `json:"from"`
	To    *int64 `json:"to"`
}

// storyRef names a Story an activity is in.
type storyRef struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// rowScanner is the common surface of pgx.Row (QueryRow) and pgx.Rows (Query's iteration) —
// scanActivityRow works against either, so the single-row lookup in handleUpdateActivity and
// the list loop in handleListActivities share one place that knows the column order and the
// bbox-from-four-nullable-floats shape, rather than duplicating it.
type rowScanner interface {
	Scan(dest ...any) error
}

func scanActivityRow(row rowScanner) (activityRow, error) {
	var a activityRow
	// Four nullable floats rather than one bbox type: they are null together, since a row
	// either has a trajectory or doesn't, but pgx has no reason to know that.
	var minLon, minLat, maxLon, maxLat *float64
	var splitGroup *string
	var split splitRef
	var avail activityAvailability
	if err := row.Scan(&a.ID, &a.StartedAt, &a.Timezone, &a.ActivityType, &a.Name, &a.DistanceMeters, &a.DurationSeconds, &a.Description,
		&minLon, &minLat, &maxLon, &maxLat, &a.Pending, &a.Edited, &a.Private, &avail.hasOriginal, &avail.editableTimes,
		&splitGroup, &split.From, &split.To, &a.Stories); err != nil {
		return activityRow{}, err
	}
	avail.pending, avail.private = a.Pending, a.Private
	a.TrackEdit, a.Photos = avail.trackEdit(), avail.photos()
	if splitGroup != nil {
		split.Group = *splitGroup
		a.Split = &split
	}
	if minLon != nil && minLat != nil && maxLon != nil && maxLat != nil {
		a.BBox = []float64{*minLon, *minLat, *maxLon, *maxLat}
	}
	return a, nil
}

type activitiesResponse struct {
	Activities []activityRow `json:"activities"`
	// Types is what a client shows for each type the rows use, once per type rather than per row.
	Types map[string]activitytype.Info `json:"types"`
}

// handleListActivities serves IMPLEMENTATION.md §4.7's
// `GET /v1/activities?from=&to=&types=`: the user's own history as rows, newest first,
// unpaginated — see listActivitiesQuery's doc comment for why. Reads the authenticated user
// from userIDFromContext (requireAuth, server.go) rather than a query parameter, same as
// every other data handler.
func (s *Server) handleListActivities(w http.ResponseWriter, r *http.Request) {
	filter, err := parseActivityFilter(r.URL.Query())
	if err != nil {
		writeAPIError(w, err.Error(), http.StatusBadRequest)
		return
	}

	rows, err := s.pool.Query(r.Context(), listActivitiesQuery, userIDFromContext(r.Context()), filter.From, filter.To, filter.Types, filter.Story)
	if err != nil {
		s.log.Error("activity list query failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	// Non-nil zero-length, so an empty history serialises as [] rather than null.
	list := make([]activityRow, 0)
	for rows.Next() {
		a, err := scanActivityRow(rows)
		if err != nil {
			s.log.Error("activity list scan failed", "err", err)
			writeAPIError(w, "internal error", http.StatusInternalServerError)
			return
		}
		list = append(list, a)
	}
	if err := rows.Err(); err != nil {
		s.log.Error("activity list read failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}

	types := make([]string, 0, len(list))
	for _, a := range list {
		types = append(types, a.ActivityType)
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, activitiesResponse{Activities: list, Types: activitytype.Describe(types, requestLang(r))})
}

// maxActivityTypeLen matches activities.activity_type's own VARCHAR(50) — rejecting an
// over-length value here is a clearer 400 than letting Postgres reject the UPDATE.
const maxActivityTypeLen = 50

// maxActivityDescriptionLen is a generous free-text bound (about the length of a couple of
// paragraphs), not a claim that anyone needs that much — the same "reject an obvious mistake,
// not opine on reasonable length" reasoning.
const maxActivityDescriptionLen = 2000

// maxActivityNameLen matches migrations/0002_activities.sql's VARCHAR(200) — a single-line
// title bound, deliberately shorter than maxActivityDescriptionLen: anything longer belongs
// in the description field, not the row's primary line.
const maxActivityNameLen = 200

// activityByIDQuery is the single-row counterpart to listActivitiesQuery, same column order
// (scanActivityRow's Scan call is shared between both), scoped by id and owner exactly like
// trackMetricsQuery — a non-owned or nonexistent id is indistinguishable from "not found."
var activityByIDQuery = `
SELECT id, started_at, timezone, activity_type, name, distance_meters, duration_seconds, description,
       ` + activityBBoxColumns + `,
       edit_pending, track_edit IS NOT NULL, trajectory IS NULL, raw_payload_key IS NOT NULL, editable_times,
       split_group, split_from, split_to,
       ` + activityStoriesColumn + `
FROM activities
WHERE id = $1 AND user_id = $2`

type updateActivityRequest struct {
	ActivityType string `json:"activity_type"`
	Name         string `json:"name"`
	Description  string `json:"description"`
}

// activityIDFromPath is the {id} of an /activities/…/{id} route, lowercased, or a 404 for one
// that isn't a UUID. Postgres refuses a malformed uuid with an error, which reached the client
// as a 500; and it accepts an uppercase one, which would then miss object keys built from the
// id (the delete's mask prefix) while still matching the row.
func activityIDFromPath(w http.ResponseWriter, r *http.Request) (string, bool) {
	id := r.PathValue("id")
	if !uuidPattern.MatchString(id) {
		writeAPIError(w, "activity not found", http.StatusNotFound)
		return "", false
	}
	return strings.ToLower(id), true
}

// handleUpdateActivity serves `PATCH /v1/activities/{id}` (docs/SPEC.md FR-5.10) — the "rename a
// mis-tagged upload" / "describe a non-sport GPS trace" feature. activity_type is free-form
// (IMPLEMENTATION.md §4.7), not a controlled vocabulary, so a manual rename here is
// architecturally identical to what ingest itself already writes — nothing to validate
// against an allow-list, just a length bound matching the column.
//
// Full-replace-on-save, not per-field PATCH semantics, matching account.go's
// handleUpdateSettings: one Save button in the edit dialog commits all three fields at once.
// Empty name/description means "clear it," written as NULLIF the same way every other
// optional text column here already is; activity_type has no such escape hatch since the
// column is NOT NULL — an empty value is rejected outright rather than silently kept
// unchanged.
func (s *Server) handleUpdateActivity(w http.ResponseWriter, r *http.Request) {
	activityID, ok := activityIDFromPath(w, r)
	if !ok {
		return
	}
	userID := userIDFromContext(r.Context())

	var req updateActivityRequest
	if err := decodeJSON(r.Body, &req); err != nil {
		writeAPIError(w, bodyError(err, "invalid request body"), http.StatusBadRequest)
		return
	}
	req.ActivityType = strings.TrimSpace(req.ActivityType)
	req.Name = strings.TrimSpace(req.Name)
	req.Description = strings.TrimSpace(req.Description)
	if req.ActivityType == "" {
		httpErrorT(w, r, http.StatusBadRequest, "error.activity_type_required")
		return
	}
	if len(req.ActivityType) > maxActivityTypeLen {
		httpErrorT(w, r, http.StatusBadRequest, "error.activity_type_too_long", "max", maxActivityTypeLen)
		return
	}
	if len(req.Name) > maxActivityNameLen {
		httpErrorT(w, r, http.StatusBadRequest, "error.activity_name_too_long", "max", maxActivityNameLen)
		return
	}
	if len(req.Description) > maxActivityDescriptionLen {
		httpErrorT(w, r, http.StatusBadRequest, "error.activity_description_too_long", "max", maxActivityDescriptionLen)
		return
	}

	ctx := r.Context()
	tag, err := s.pool.Exec(ctx, `
		UPDATE activities SET activity_type = $3, name = NULLIF($4, ''), description = NULLIF($5, '')
		WHERE id = $1 AND user_id = $2
	`, activityID, userID, req.ActivityType, req.Name, req.Description)
	if err != nil {
		s.log.Error("activity update failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	if tag.RowsAffected() == 0 {
		writeAPIError(w, "activity not found", http.StatusNotFound)
		return
	}
	// activity_type is in every tracks tile this activity crosses, and no render follows.
	if err := fog.BumpMapVersion(ctx, s.pool, userID); err != nil {
		s.log.Error("activity update: bump map version failed", "activity_id", activityID, "err", err)
	}

	row, err := scanActivityRow(s.pool.QueryRow(ctx, activityByIDQuery, activityID, userID))
	if err != nil {
		s.log.Error("activity lookup after update failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, row)
}

// handleDeleteActivity serves `DELETE /v1/activities/{id}` (§4.7.5) — a full purge, not a
// soft delete: the DB cascade already handles activity_tile_masks (`ON DELETE CASCADE`
// back to activities.id), and Trends is live-aggregated over whatever
// rows remain, so neither needs any explicit cleanup here. Two things genuinely do:
//
//   - Object storage has no foreign keys, so the raw upload
//     and this activity's rendered fog/heatmap masks have to be removed explicitly.
//   - Fog and Heatmap both read a precomputed per-user, per-tile cache that ingest builds by
//     compositing activity_tile_masks rows together, but only ingest ever marks a tile dirty
//     or enqueues its re-render — deleting an activity would otherwise cascade its masks away
//     while leaving that cache's already-rendered PNGs stale indefinitely, still showing
//     coverage for an activity that no longer exists.
//
// Runs synchronously in the handler, like handleUpdateActivity/handleDeleteAvatar: unlike
// ingest's parsing, everything here (a row delete, a couple of small queries, an
// object-storage prefix removal) is cheap enough not to need the job queue itself — only the
// actual tile re-render at the end goes through it, the same render_fog job ingest already
// relies on.
func (s *Server) handleDeleteActivity(w http.ResponseWriter, r *http.Request) {
	activityID, ok := activityIDFromPath(w, r)
	if !ok {
		return
	}
	userID := userIDFromContext(r.Context())
	ctx := r.Context()

	// Read back what the cascade is about to delete out from under us — both are needed only
	// for cleanup below, and both would be gone (or unrecoverable) once the DELETE runs.
	var rawKey *string
	if err := s.pool.QueryRow(ctx,
		`SELECT raw_payload_key FROM activities WHERE id = $1 AND user_id = $2`, activityID, userID,
	).Scan(&rawKey); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			writeAPIError(w, "activity not found", http.StatusNotFound)
			return
		}
		s.log.Error("activity lookup before delete failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}

	tiles, err := ingest.ActivityTiles(ctx, s.pool, activityID)
	if err != nil {
		s.log.Error("activity tile lookup before delete failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}

	// The activity's photos (§4.27) go with it; the cascade takes their rows, so their images
	// have to be removed explicitly — after the rows, since a copied Story's photo (§4.23) can
	// share them and keeps them.
	photoKeys, err := s.activityPhotoKeys(ctx, activityID)
	if err != nil {
		s.log.Error("activity delete: photo lookup failed, deleting row anyway", "activity_id", activityID, "err", err)
	}
	if rawKey != nil {
		// raw_payload_key is content-addressed (raw/{userID}/{sha256(bytes)}{ext}), not
		// scoped by source — two distinct activities can share one key if their raw bytes are
		// byte-identical (e.g. the same file uploaded twice, or an activity in a copied Story).
		// Only remove it if this is the last activity actually pointing at
		// it, or a sibling activity's still-referenced raw file disappears with this one.
		var stillReferenced bool
		if err := s.pool.QueryRow(ctx,
			`SELECT EXISTS(SELECT 1 FROM activities WHERE raw_payload_key = $1 AND id != $2)`, *rawKey, activityID,
		).Scan(&stillReferenced); err != nil {
			s.log.Error("activity delete: raw key reference check failed, skipping raw cleanup", "activity_id", activityID, "err", err)
		} else if !stillReferenced {
			if err := s.store.Remove(ctx, *rawKey); err != nil {
				s.log.Error("activity delete: raw payload cleanup failed, deleting row anyway", "activity_id", activityID, "err", err)
			}
		}
	}

	tag, err := s.pool.Exec(ctx, `DELETE FROM activities WHERE id = $1 AND user_id = $2`, activityID, userID)
	if err != nil {
		s.log.Error("activity delete failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	if tag.RowsAffected() == 0 {
		writeAPIError(w, "activity not found", http.StatusNotFound)
		return
	}
	s.removeUnreferencedPhotoFiles(ctx, photoKeys)
	// The track is gone from the tracks tiles now; the render below only bumps once it runs.
	if err := fog.BumpMapVersion(ctx, s.pool, userID); err != nil {
		s.log.Error("activity delete: bump map version failed", "activity_id", activityID, "err", err)
	}

	// The fix for the stale-cache risk above: re-trigger the exact same dirty-mark-and-render
	// machinery ingest uses, just from removal instead of addition. RenderUser's own render is
	// "idempotent and complete per tile, not incremental" — it fully recomposites a tile from
	// whatever activity_tile_masks rows currently exist, so simply re-triggering it against
	// the now-smaller set (this activity's rows already gone via the cascade above) produces a
	// correct result with no new compositing logic needed.
	if len(tiles) > 0 {
		if err := ingest.MarkFogTilesDirty(ctx, s.pool, userID, tiles); err != nil {
			s.log.Error("activity delete: mark fog tiles dirty failed", "activity_id", activityID, "err", err)
		} else if err := ingest.EnqueueRenderFog(ctx, s.pool, userID); err != nil {
			s.log.Error("activity delete: enqueue render_fog failed", "activity_id", activityID, "err", err)
		}
	}

	w.WriteHeader(http.StatusNoContent)
}

// trackMetricsQuery reads one activity's already-simplified display trajectory back out
// (ST_DumpPoints, same shape simplifyXY already produces at ingest — this just reads it
// instead of simplifying fresh). The M ordinate is epoch seconds per §3.3, which is all a
// per-vertex speed needs besides position.
const trackMetricsQuery = `
SELECT array_agg(ST_X(pt.geom) ORDER BY pt.path),
       array_agg(ST_Y(pt.geom) ORDER BY pt.path),
       array_agg(ST_M(pt.geom) ORDER BY pt.path)
FROM activities a
CROSS JOIN LATERAL ST_DumpPoints(a.trajectory) AS pt
WHERE a.id = $1 AND a.user_id = $2
GROUP BY a.id`

type trackMetricPoint struct {
	Lon      float64 `json:"lon"`
	Lat      float64 `json:"lat"`
	SpeedMps float64 `json:"speed_mps"`
	// TimeS is the point's moment, epoch seconds — what the Edit window's photo slider (§4.27)
	// turns a place on the track into.
	TimeS int64 `json:"time_s"`
}

type trackMetricsResponse struct {
	ActivityID string             `json:"activity_id"`
	Points     []trackMetricPoint `json:"points"`
	Bands      []paceBand         `json:"bands"`
}

// pointSpeeds is each point's speed from the one before it, in m/s: 0 across no time, and the
// first point takes the second's. ms is the M ordinate, epoch seconds, read in whole seconds.
func pointSpeeds(lons, lats, ms []float64) []float64 {
	n := len(lons)
	speed := make([]float64, n)
	for i := 1; i < n; i++ {
		if dt := float64(int64(ms[i]) - int64(ms[i-1])); dt > 0 {
			speed[i] = ingest.HaversineM(lats[i-1], lons[i-1], lats[i], lons[i]) / dt
		}
	}
	if n > 1 {
		speed[0] = speed[1]
	}
	return speed
}

// handleActivityTrackMetrics serves `GET /v1/activities/{id}/track-metrics` — per-simplified-
// vertex speed, and the pace bands (paceBands) the web and Android clients draw over whichever
// single activity is selected. Pace only: HoldMyTrack keeps no heart rate (VISION.md §1.1).
// Scoped to the caller's user_id in the query itself, same as every other per-activity lookup
// here: a non-owned or nonexistent id is indistinguishable from "not found," nothing new to
// invent.
func (s *Server) handleActivityTrackMetrics(w http.ResponseWriter, r *http.Request) {
	activityID, ok := activityIDFromPath(w, r)
	if !ok {
		return
	}

	var lons, lats, ms []float64
	err := s.pool.QueryRow(r.Context(), trackMetricsQuery, activityID, userIDFromContext(r.Context())).
		Scan(&lons, &lats, &ms)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			writeAPIError(w, "activity not found", http.StatusNotFound)
			return
		}
		s.log.Error("track metrics query failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}

	speed := pointSpeeds(lons, lats, ms)
	points := make([]trackMetricPoint, len(lons))
	for i := range points {
		points[i] = trackMetricPoint{Lon: lons[i], Lat: lats[i], SpeedMps: speed[i], TimeS: int64(ms[i])}
	}

	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, trackMetricsResponse{ActivityID: activityID, Points: points, Bands: paceBands(speed)})
}
