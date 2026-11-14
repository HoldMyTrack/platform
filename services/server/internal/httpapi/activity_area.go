package httpapi

import (
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/HoldMyTrack/platform/services/server/internal/activitytype"
)

// areaActivitiesLimit caps the web's area list, and so its map (docs/SPEC.md FR-5.11): a heavy
// user's home area holds thousands, and the response says how many, so the client can say the
// rest is out of view.
const areaActivitiesLimit = 1000

// areaRowColumns is a slim row: what a list row shows and what flying to it needs. The Edit
// window reads the rest (GET /v1/activities/{id}). Order matches scanAreaRow.
var areaRowColumns = `id, started_at, timezone, activity_type, name, distance_meters,
       COALESCE(moving_seconds, duration_seconds),
       ` + activityBBoxColumns + `,
       edit_pending, trajectory IS NULL,
       ` + activityStoriesColumn

// areaFilterSQL is the area list's WHERE: the owner $1 and Dates $2/$3.
var areaFilterSQL = `user_id = $1 AND ` + inDateRange("$2", "$3")

// listAreaQuery is the newest $4 activities, at every zoom, for the opening view; with an area,
// listInAreaQuery is those crossing it ($5–$10), and countInAreaQuery their total past the limit.
// The total counts tracks whose box reaches the view, which the index answers alone: testing every
// line took 400 ms for an area of 15,000 tracks against 70 ms, and miscounted 2 of them.
var listAreaQuery = `SELECT ` + areaRowColumns + ` FROM activities WHERE ` + areaFilterSQL + `
ORDER BY started_at DESC, id DESC LIMIT $4`

var listInAreaQuery = `SELECT ` + areaRowColumns + ` FROM activities WHERE ` + areaFilterSQL + `
  AND ` + trajectoryInAreaSQL(5, true) + `
ORDER BY started_at DESC, id DESC LIMIT $4`

var countInAreaQuery = `SELECT count(*) FROM activities WHERE ` + areaFilterSQL + ` AND ` + trajectoryInAreaSQL(4, false)

// trajectoryInAreaSQL is "the track crosses one of the area's two boxes" (mapArea.boxes), with
// the parameters from $first: south, north, then each box's west and east. A track stored past
// ±180 (§4.1) is matched by the boxes moved a world's width, as the tracks tile matches it. Each
// test is its own && against constant parameters, so idx_activities_spatial answers the OR; exact
// then drops, with ST_Intersects, a track whose box reaches the view while the line doesn't.
func trajectoryInAreaSQL(first int, exact bool) string {
	p := func(i int) string { return fmt.Sprintf("$%d::float8", first+i) }
	var tests []string
	for _, box := range [][2]string{{p(2), p(3)}, {p(4), p(5)}} {
		for _, shift := range []string{"", " + 360", " - 360"} {
			env := "ST_MakeEnvelope(" + box[0] + shift + ", " + p(0) + ", " + box[1] + shift + ", " + p(1) + ", 4326)"
			test := "trajectory && " + env
			if exact {
				test += " AND ST_Intersects(trajectory, " + env + ")"
			}
			tests = append(tests, "("+test+")")
		}
	}
	return "(" + strings.Join(tests, "\n    OR ") + ")"
}

// areaRow is one slim row of the area list.
type areaRow struct {
	ID             string     `json:"id"`
	StartedAt      time.Time  `json:"started_at"`
	Timezone       string     `json:"timezone"`
	ActivityType   string     `json:"activity_type"`
	Name           *string    `json:"name"`
	DistanceMeters *float64   `json:"distance_meters"`
	MovingSeconds  *int32     `json:"moving_seconds"`
	BBox           []float64  `json:"bbox"`
	Pending        bool       `json:"pending"`
	Private        bool       `json:"private"`
	Stories        []storyRef `json:"stories"`
}

func scanAreaRow(row rowScanner) (areaRow, error) {
	var a areaRow
	var minLon, minLat, maxLon, maxLat *float64
	if err := row.Scan(&a.ID, &a.StartedAt, &a.Timezone, &a.ActivityType, &a.Name, &a.DistanceMeters, &a.MovingSeconds,
		&minLon, &minLat, &maxLon, &maxLat, &a.Pending, &a.Private, &a.Stories); err != nil {
		return areaRow{}, err
	}
	if minLon != nil && minLat != nil && maxLon != nil && maxLat != nil {
		a.BBox = []float64{*minLon, *minLat, *maxLon, *maxLat}
	}
	return a, nil
}

type areaResponse struct {
	Activities []areaRow                    `json:"activities"`
	Types      map[string]activitytype.Info `json:"types"`
	// Total is how many activities the area holds, sent with `bbox` alone; more than
	// len(Activities) when the list was cut at the limit.
	Total *int `json:"total,omitempty"`
}

// handleListArea serves `GET /v1/activities/area?bbox=&from=&to=&limit=`, the web's list and the
// set its map draws (docs/SPEC.md FR-5.11): the newest activities whose track crosses the view,
// areaActivitiesLimit at most, with the area's total. Without `bbox`, the newest `limit` of the
// whole history, for the opening view (FR-4.4).
func (s *Server) handleListArea(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	filter, err := parseActivityFilter(q)
	if err != nil {
		writeAPIError(w, err.Error(), http.StatusBadRequest)
		return
	}
	limit := areaActivitiesLimit
	if raw := q.Get("limit"); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil || n < 1 || n > areaActivitiesLimit {
			writeAPIError(w, fmt.Sprintf("limit must be 1 to %d", areaActivitiesLimit), http.StatusBadRequest)
			return
		}
		limit = n
	}
	var area *mapArea
	if raw := q.Get("bbox"); raw != "" {
		a, ok := parseBBox(raw)
		if !ok {
			writeAPIError(w, "bbox must be west,south,east,north in degrees, south < north", http.StatusBadRequest)
			return
		}
		area = &a
	}

	ctx := r.Context()
	base := []any{userIDFromContext(ctx), filter.From, filter.To}
	query, args := listAreaQuery, append(base, limit)
	var areaArgs []any
	if area != nil {
		w1, e1, w2, e2 := area.boxes()
		areaArgs = []any{area.south, area.north, w1, e1, w2, e2}
		query, args = listInAreaQuery, append(args, areaArgs...)
	}
	list, err := readRows(ctx, s, query, scanAreaRow, args...)
	if err != nil {
		if clientGone(w, r) {
			return
		}
		s.log.Error("activity area query failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}

	resp := areaResponse{Activities: list}
	if area != nil {
		total := len(list)
		// Only a full list can have more behind it.
		if total == limit {
			if err := s.pool.QueryRow(ctx, countInAreaQuery, append(base, areaArgs...)...).Scan(&total); err != nil {
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

// handleGetActivity serves `GET /v1/activities/{id}`: one full row, as the list of a date range
// or a Story has it, for the Edit window the area list's slim rows don't carry enough for. Another
// account's activity is a 404, like a missing one.
func (s *Server) handleGetActivity(w http.ResponseWriter, r *http.Request) {
	id, ok := activityIDFromPath(w, r)
	if !ok {
		return
	}
	a, err := scanActivityRow(s.pool.QueryRow(r.Context(), activityByIDQuery, id, userIDFromContext(r.Context())))
	if errors.Is(err, pgx.ErrNoRows) {
		writeAPIError(w, "activity not found", http.StatusNotFound)
		return
	}
	if err != nil {
		if clientGone(w, r) {
			return
		}
		s.log.Error("activity read failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, activitiesResponse{Activities: []activityRow{a}, Types: activitytype.Describe([]string{a.ActivityType}, requestLang(r))})
}
