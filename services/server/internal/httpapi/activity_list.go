package httpapi

import (
	"context"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/HoldMyTrack/platform/services/server/internal/activitytype"
)

// listActivitiesQuery is §4.7's list, with §4.3's "$n IS NULL OR ..." optional-filter
// treatment, and $6 a LIMIT, NULL for none. No pagination: the client renders every matching
// row on the map and computes stats and type/distance facets across all of them at once, so a
// partial page was never usable. An account's activity count is in the hundreds to low
// thousands; the web's area list (listActivitiesInAreaQuery) caps its own.
//
// The four ST_*Min/Max calls are the row's bounding box, so a client can fly the map to an
// activity without a follow-up request per row. They are cheaper than they look: PostGIS
// caches a geometry's bounding box in its header, so this reads that rather than walking
// the vertices. §3.3 has no bbox column and doesn't need one back.
//
// Column order here has to match scanActivityRow's Scan call exactly — activityByIDQuery
// below shares that same order for the same reason.
var listActivitiesQuery = listActivitiesSelect + `
ORDER BY started_at DESC, id DESC
LIMIT $6::int`

// listActivitiesInAreaQuery is the list narrowed to the tracks crossing a map view (FR-5.19),
// $7–$12 as trajectoryInAreaSQL takes them; countActivitiesInAreaQuery is its total, past the
// limit.
var listActivitiesInAreaQuery = listActivitiesSelect + `
  AND ` + trajectoryInAreaSQL(7) + `
ORDER BY started_at DESC, id DESC
LIMIT $6::int`

var countActivitiesInAreaQuery = `
SELECT count(*) FROM activities
WHERE user_id = $1
  AND ` + inDateRange("$2", "$3") + `
  AND ($4::text[] IS NULL OR activity_type = ANY($4))
  AND ($5::uuid IS NULL OR activities.id IN (SELECT activity_id FROM story_activities WHERE story_id = $5))
  AND ` + trajectoryInAreaSQL(6)

var listActivitiesSelect = `
SELECT id, started_at, timezone, activity_type, name, distance_meters, duration_seconds,
       COALESCE(moving_seconds, duration_seconds), description,
       ` + activityBBoxColumns + `,
       edit_pending, track_edit IS NOT NULL, trajectory IS NULL, raw_payload_key IS NOT NULL, editable_times,
       split_group, split_from, split_to,
       ` + activityStoriesColumn + `
FROM activities
WHERE user_id = $1
  AND ` + inDateRange("$2", "$3") + `
  AND ($4::text[] IS NULL OR activity_type = ANY($4))
  AND ($5::uuid IS NULL OR activities.id IN (SELECT activity_id FROM story_activities WHERE story_id = $5))`

// areaActivitiesLimit caps the area list (FR-5.19): a heavy user's home area holds thousands,
// and the response says how many, so the client can ask for a smaller area.
const areaActivitiesLimit = 1000

// trajectoryInAreaSQL is "the track crosses one of the area's two boxes" (mapArea.boxes), with
// the parameters from $first: south, north, then each box's west and east. A track stored past
// ±180 (§4.1) is matched by the boxes moved a world's width, as the tracks tile matches it. Each
// test is its own && against constant parameters, so idx_activities_spatial answers the OR, and
// ST_Intersects then drops a track whose box reaches the view while the line doesn't.
func trajectoryInAreaSQL(first int) string {
	p := func(i int) string { return fmt.Sprintf("$%d::float8", first+i) }
	var tests []string
	for _, box := range [][2]string{{p(2), p(3)}, {p(4), p(5)}} {
		for _, shift := range []string{"", " + 360", " - 360"} {
			env := "ST_MakeEnvelope(" + box[0] + shift + ", " + p(0) + ", " + box[1] + shift + ", " + p(1) + ", 4326)"
			tests = append(tests, "(trajectory && "+env+" AND ST_Intersects(trajectory, "+env+"))")
		}
	}
	return "(" + strings.Join(tests, "\n    OR ") + ")"
}

// activityRow is one row of the list. The field set is exactly what the Activities panel
// renders, no more. MovingSeconds is the time a row shows, the same time Stories and Trends
// sum, so a Story's total is its rows added up. Like them, it falls back to the elapsed
// DurationSeconds where moving time is unset.
//
// Name (migrations/0002_activities.sql) is a user-entered title, nullable — a row with
// none has never had one set, and the client falls back to started_at for its primary line
// (§4.7 revised its earlier "no name column" decision to add exactly this, and nothing
// more: still no parser reads a name out of a source file). Description (docs/SPEC.md FR-5.10,
// migrations/0002_activities.sql's activities.description) stays separate free-text, shown only
// as a hover tooltip — a row with nothing written there has never been edited, not "an
// empty description."
//
// The metric fields are nullable in §3.3 and stay nullable here rather than being
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
	// Private is an activity entirely inside the account's Private locations (FR-8.1): kept,
	// with no track, so no distance or duration worth showing — the panel badges it instead.
	// A NULL trajectory has no other cause (§3.3).
	Private bool `json:"private"`
	// TrackEdit and Photos say why the Edit window's Track or Photos tab can't be used for this
	// activity (activity_availability.go), omitted when it can.
	TrackEdit string `json:"track_edit,omitempty"`
	Photos    string `json:"photos,omitempty"`
	// Split is set on a piece of a split activity (§4.7.8): which split, and the stretch of the
	// recording it covers.
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
	if err := row.Scan(&a.ID, &a.StartedAt, &a.Timezone, &a.ActivityType, &a.Name, &a.DistanceMeters, &a.DurationSeconds, &a.MovingSeconds, &a.Description,
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
	// Total is how many activities the area holds, sent with `bbox` alone; more than
	// len(Activities) when the list was cut at the limit.
	Total *int `json:"total,omitempty"`
}

// handleListActivities serves IMPLEMENTATION.md §4.7's
// `GET /v1/activities?from=&to=&types=&story=&bbox=&limit=`: the user's own history as rows,
// newest first, unpaginated — see listActivitiesQuery's doc comment for why. With `bbox`, only
// the tracks crossing that view, at most areaActivitiesLimit of them, and the area's total.
func (s *Server) handleListActivities(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	filter, err := parseActivityFilter(q)
	if err != nil {
		writeAPIError(w, err.Error(), http.StatusBadRequest)
		return
	}
	limit, err := parseListLimit(q.Get("limit"))
	if err != nil {
		writeAPIError(w, err.Error(), http.StatusBadRequest)
		return
	}
	var area *mapArea
	if raw := q.Get("bbox"); raw != "" {
		a, ok := parseBBox(raw)
		if !ok {
			writeAPIError(w, "bbox must be west,south,east,north in degrees, south < north", http.StatusBadRequest)
			return
		}
		area = &a
		if limit == nil {
			l := areaActivitiesLimit
			limit = &l
		}
	}

	ctx := r.Context()
	userID := userIDFromContext(ctx)
	args := []any{userID, filter.From, filter.To, filter.Types, filter.Story, limit}
	query := listActivitiesQuery
	var areaArgs []any
	if area != nil {
		w1, e1, w2, e2 := area.boxes()
		areaArgs = []any{area.south, area.north, w1, e1, w2, e2}
		args = append(args, areaArgs...)
		query = listActivitiesInAreaQuery
	}
	list, err := s.readActivityRows(ctx, query, args...)
	if err != nil {
		if clientGone(w, r) {
			return
		}
		s.log.Error("activity list query failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}

	resp := activitiesResponse{Activities: list}
	if area != nil {
		total := len(list)
		// Only a full page can have more behind it.
		if total == *limit {
			countArgs := append([]any{userID, filter.From, filter.To, filter.Types, filter.Story}, areaArgs...)
			if err := s.pool.QueryRow(ctx, countActivitiesInAreaQuery, countArgs...).Scan(&total); err != nil {
				if clientGone(w, r) {
					return
				}
				s.log.Error("activity area count failed", "err", err)
				writeAPIError(w, "internal error", http.StatusInternalServerError)
				return
			}
		}
		resp.Total = &total
	}

	types := make([]string, 0, len(list))
	for _, a := range list {
		types = append(types, a.ActivityType)
	}
	resp.Types = activitytype.Describe(types, requestLang(r))
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, resp)
}

// readActivityRows runs a list query and scans its rows, an empty history as [] rather than null.
func (s *Server) readActivityRows(ctx context.Context, query string, args ...any) ([]activityRow, error) {
	rows, err := s.pool.Query(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	list := make([]activityRow, 0)
	for rows.Next() {
		a, err := scanActivityRow(rows)
		if err != nil {
			return nil, err
		}
		list = append(list, a)
	}
	return list, rows.Err()
}

// parseListLimit reads the list's optional `limit`, nil when absent: 1 to areaActivitiesLimit,
// the newest that many, for the web's opening view.
func parseListLimit(raw string) (*int, error) {
	if raw == "" {
		return nil, nil
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n < 1 || n > areaActivitiesLimit {
		return nil, fmt.Errorf("limit must be 1 to %d", areaActivitiesLimit)
	}
	return &n, nil
}
