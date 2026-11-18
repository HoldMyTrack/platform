package httpapi

import (
	"context"
	"net/http"
	"time"

	"github.com/HoldMyTrack/platform/services/server/internal/tracktype"
)

// listActivitiesQuery is §4.7's list, with §4.3's "$n IS NULL OR ..." optional-filter
// treatment. No pagination: the client renders every matching row on the map and computes stats
// and type/distance facets across all of them at once, so a partial page was never usable. The
// apps' date range and a Story read it; the web's area list is activity_area.go's.
//
// The four ST_*Min/Max calls are the row's bounding box, so a client can fly the map to an
// track without a follow-up request per row. They are cheaper than they look: PostGIS
// caches a geometry's bounding box in its header, so this reads that rather than walking
// the vertices. §3.3 has no bbox column and doesn't need one back.
//
// Column order here has to match scanActivityRow's Scan call exactly — activityByIDQuery
// shares that same order for the same reason.
var listTracksQuery = `
SELECT id, started_at, timezone, activity_type, name, distance_meters, duration_seconds,
       COALESCE(moving_seconds, duration_seconds), description,
       ` + trackBBoxColumns + `,
       edit_pending, track_edit IS NOT NULL, trajectory IS NULL, raw_payload_key IS NOT NULL, editable_times,
       split_group, split_from, split_to,
       ` + trackTripsColumn + `
FROM activities
WHERE user_id = $1
  AND ` + inDateRange("$2", "$3") + `
  AND ($4::text[] IS NULL OR activity_type = ANY($4))
  AND ($5::uuid IS NULL OR activities.id IN (SELECT activity_id FROM story_activities WHERE story_id = $5))
ORDER BY started_at DESC, id DESC`

// activityRow is one row of the list. The field set is exactly what the Tracks panel
// renders, no more. MovingSeconds is the time a row shows, the same time Stories and Trends
// sum, so a Story's total is its rows added up. Like them, it falls back to the elapsed
// DurationSeconds where moving time is unset.
//
// Name is a user-entered title, nullable: a row with none has never had one set, and the
// client falls back to started_at for its primary line. No parser reads a name out of a
// source file. Description (docs/SPEC.md FR-5.5) is separate free text, shown only as a hover
// tooltip.
//
// The metric fields are nullable in §3.3 and stay nullable here rather than being
// coerced to 0: a file that carried no distance is not a zero-distance track.
type trackRow struct {
	ID        string    `json:"id"`
	StartedAt time.Time `json:"started_at"`
	// Timezone is the IANA zone it was recorded in (§4.30): a client shows StartedAt, and any
	// other time of this track's, in it.
	Timezone        string   `json:"timezone"`
	TrackType       string   `json:"activity_type"`
	Name            *string  `json:"name"`
	DistanceMeters  *float64 `json:"distance_meters"`
	DurationSeconds *int32   `json:"duration_seconds"`
	MovingSeconds   *int32   `json:"moving_seconds"`
	Description     *string  `json:"description"`
	// [minLon, minLat, maxLon, maxLat] — GeoJSON's bbox ordering — or null when the row has
	// no geometry. §3.3 allows a null trajectory, and a client must not fly the map nowhere.
	BBox []float64 `json:"bbox"`
	// Pending is true while an Edit track reprocess (§4.7.7) is queued or running — the row's
	// numbers and geometry are still the pre-edit ones. Edited is true once the track carries
	// a user edit, which is what makes "Reset to original track" meaningful.
	Pending bool `json:"pending"`
	Edited  bool `json:"edited"`
	// Private is a track entirely inside the account's Private locations (FR-7.1): kept,
	// with no track, so no distance or duration worth showing — the panel badges it instead.
	// A NULL trajectory has no other cause (§3.3).
	Private bool `json:"private"`
	// RouteEdit and Photos say why the Edit window's Track or Photos tab can't be used for this
	// track (activity_availability.go), omitted when it can.
	RouteEdit string `json:"track_edit,omitempty"`
	Photos    string `json:"photos,omitempty"`
	// Split is set on a piece of a split track (§4.7.8): which split, and the stretch of the
	// recording it covers.
	Split *splitRef `json:"split"`
	// Stories are the Stories it's in, newest first — the Tracks panel's Story badge.
	Trips []tripRef `json:"stories"`
}

// splitRef places a piece within its split: From and To are unix-ms point timestamps, null
// at the recording's own ends. Pieces meet where one's To is the next one's From.
type splitRef struct {
	Group string `json:"group"`
	From  *int64 `json:"from"`
	To    *int64 `json:"to"`
}

// storyRef names a Story a track is in.
type tripRef struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// rowScanner is the common surface of pgx.Row and pgx.Rows, so scanActivityRow serves the
// single-row lookup and the list loop alike.
type rowScanner interface {
	Scan(dest ...any) error
}

func scanTrackRow(row rowScanner) (trackRow, error) {
	var a trackRow
	// Four nullable floats rather than one bbox type: they are null together, since a row
	// either has a trajectory or doesn't, but pgx has no reason to know that.
	var minLon, minLat, maxLon, maxLat *float64
	var splitGroup *string
	var split splitRef
	var avail trackAvailability
	if err := row.Scan(&a.ID, &a.StartedAt, &a.Timezone, &a.TrackType, &a.Name, &a.DistanceMeters, &a.DurationSeconds, &a.MovingSeconds, &a.Description,
		&minLon, &minLat, &maxLon, &maxLat, &a.Pending, &a.Edited, &a.Private, &avail.hasOriginal, &avail.editableTimes,
		&splitGroup, &split.From, &split.To, &a.Trips); err != nil {
		return trackRow{}, err
	}
	avail.pending, avail.private = a.Pending, a.Private
	a.RouteEdit, a.Photos = avail.routeEdit(), avail.photos()
	if splitGroup != nil {
		split.Group = *splitGroup
		a.Split = &split
	}
	if minLon != nil && minLat != nil && maxLon != nil && maxLat != nil {
		a.BBox = []float64{*minLon, *minLat, *maxLon, *maxLat}
	}
	return a, nil
}

type tracksResponse struct {
	Tracks []trackRow `json:"activities"`
	// Types is what a client shows for each type the rows use, once per type rather than per row.
	Types map[string]tracktype.Info `json:"types"`
}

// handleListActivities serves IMPLEMENTATION.md §4.7's `GET /v1/activities?from=&to=&types=&story=`:
// the user's own history as rows, newest first, unpaginated — see listActivitiesQuery's doc
// comment for why.
func (s *Server) handleListTracks(w http.ResponseWriter, r *http.Request) {
	filter, err := parseTrackFilter(r.URL.Query())
	if err != nil {
		writeAPIError(w, err.Error(), http.StatusBadRequest)
		return
	}
	list, err := readRows(r.Context(), s, listTracksQuery, scanTrackRow,
		userIDFromContext(r.Context()), filter.From, filter.To, filter.Types, filter.Trip)
	if err != nil {
		if clientGone(w, r) {
			return
		}
		s.log.Error("activity list query failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	types := make([]string, 0, len(list))
	for _, a := range list {
		types = append(types, a.TrackType)
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, tracksResponse{Tracks: list, Types: tracktype.Describe(types, requestLang(r))})
}

// readRows runs a list query and scans each row with scan, an empty result as [] rather than null.
func readRows[T any](ctx context.Context, s *Server, query string, scan func(rowScanner) (T, error), args ...any) ([]T, error) {
	rows, err := s.pool.Query(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	list := make([]T, 0)
	for rows.Next() {
		v, err := scan(rows)
		if err != nil {
			return nil, err
		}
		list = append(list, v)
	}
	return list, rows.Err()
}
