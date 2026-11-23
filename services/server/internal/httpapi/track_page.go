package httpapi

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"

	"github.com/HoldMyTrack/platform/services/server/internal/tracktype"
)

// trackPageSize is how many rows one of Library's pages holds (SPEC.md FR-5.13), and so the
// most a client can check at once there.
const trackPageSize = 100

// maxTrackPage bounds `page` so its offset stays far inside an int on any account.
const maxTrackPage = 1_000_000

// maxTrackDistanceParam is the largest `min_distance` or `max_distance`, in meters: past any
// track's, and finite.
const maxTrackDistanceParam = 1e9

// maxTrackSearchLen is the longest search, in characters: a name's own limit (maxTrackNameLen).
const maxTrackSearchLen = maxTrackNameLen

// trackPage is what `page` and the parameters that need it ask for, on top of trackFilter.
type trackPage struct {
	// Page counts from 1.
	Page int
	// Sort is a key of trackSortKeys.
	Sort string
	Desc bool
	// Search is text found in the name or the description, nil for none.
	Search *string
	// MinDistance and MaxDistance are meters, both inclusive, nil for no bound.
	MinDistance *float64
	MaxDistance *float64
}

// trackSortKeys are the orders a page can take, each a tracks column or expression. A track
// with no route (FR-7.1) has no distance or moving time worth comparing, so it is NULL on those
// and sorts last either way.
var trackSortKeys = map[string]string{
	"started":  "started_at",
	"added":    "created_at",
	"distance": "(CASE WHEN trajectory IS NOT NULL THEN distance_meters END)",
	"moving":   "(CASE WHEN trajectory IS NOT NULL THEN COALESCE(moving_seconds, duration_seconds) END)",
}

// parseTrackPage reads `page`, `sort`, `q`, `min_distance` and `max_distance`. paged is false
// when `page` is absent, and the others are then refused, so the unpaged list keeps its contract.
// An empty value is no value in both modes.
func parseTrackPage(q url.Values) (p trackPage, paged bool, err error) {
	if !q.Has("page") {
		for _, name := range []string{"sort", "q", "min_distance", "max_distance"} {
			if q.Get(name) != "" {
				return trackPage{}, false, errors.New(`"` + name + `" needs "page"`)
			}
		}
		return trackPage{}, false, nil
	}
	p.Page, err = strconv.Atoi(q.Get("page"))
	if err != nil || p.Page < 1 || p.Page > maxTrackPage {
		return trackPage{}, false, errors.New(`invalid "page", want a whole number from 1`)
	}
	p.Sort, p.Desc = "started", true
	if v := q.Get("sort"); v != "" {
		key, dir, ok := strings.Cut(v, "_")
		if _, known := trackSortKeys[key]; !known || !ok || (dir != "asc" && dir != "desc") {
			return trackPage{}, false, errors.New(`invalid "sort", want started, added, distance or moving, then _asc or _desc`)
		}
		p.Sort, p.Desc = key, dir == "desc"
	}
	if v := strings.TrimSpace(q.Get("q")); v != "" {
		// Postgres refuses text that isn't UTF-8 or holds a NUL, which would be a 500.
		if !utf8.ValidString(v) || strings.ContainsRune(v, 0) {
			return trackPage{}, false, errors.New(`invalid "q", want text`)
		}
		if utf8.RuneCountInString(v) > maxTrackSearchLen {
			return trackPage{}, false, errors.New(`"q" is too long`)
		}
		p.Search = &v
	}
	for _, b := range []struct {
		name string
		dst  **float64
	}{{"min_distance", &p.MinDistance}, {"max_distance", &p.MaxDistance}} {
		v := q.Get(b.name)
		if v == "" {
			continue
		}
		m, err := strconv.ParseFloat(v, 64)
		if err != nil || m < 0 || m > maxTrackDistanceParam {
			return trackPage{}, false, errors.New(`invalid "` + b.name + `", want meters`)
		}
		*b.dst = &m
	}
	if p.MinDistance != nil && p.MaxDistance != nil && *p.MinDistance > *p.MaxDistance {
		return trackPage{}, false, errors.New(`"min_distance" is over "max_distance"`)
	}
	return p, true, nil
}

// offset is the number of rows before the page.
func (p trackPage) offset() int { return (p.Page - 1) * trackPageSize }

// trackPageWhere is a page's filter over tracks, on $1 the account, $2–$5 trackFilter's and
// $6–$8 trackPage's Search, MinDistance and MaxDistance. A search matches the name or the
// description alone, ignoring case and accents, so an unnamed track matches by its
// description only. A Distance bound leaves out a track with no route, as the panel does
// (FR-5.3).
var trackPageWhere = `user_id = $1
  AND ` + inDateRange("$2", "$3") + `
  AND ($4::text[] IS NULL OR track_type = ANY($4))
  AND ($5::uuid IS NULL OR tracks.id IN (SELECT track_id FROM trip_tracks WHERE trip_id = $5))
  AND ($6::text IS NULL
       OR strpos(unaccent(lower(COALESCE(name, ''))), unaccent(lower($6))) > 0
       OR strpos(unaccent(lower(COALESCE(description, ''))), unaccent(lower($6))) > 0)
  AND (($7::float8 IS NULL AND $8::float8 IS NULL)
       OR (trajectory IS NOT NULL AND distance_meters IS NOT NULL
           AND distance_meters::float8 >= COALESCE($7, 0)
           AND distance_meters::float8 <= COALESCE($8, 'Infinity')))`

// trackPageQuery is one page of rows in sort's order, id breaking ties in the same direction so
// tied tracks keep one order. A track added or deleted between two requests still moves the
// later pages by a row. The page's ids are picked first, so the row columns' subqueries run for
// those 100 rather than for every track the sort reads.
func trackPageQuery(sort string, desc bool) string {
	dir := " ASC"
	if desc {
		dir = " DESC"
	}
	order := trackSortKeys[sort] + dir + ` NULLS LAST, id` + dir
	return `SELECT ` + trackRowColumns + `
FROM tracks
WHERE id IN (SELECT id FROM tracks WHERE ` + trackPageWhere + `
             ORDER BY ` + order + ` LIMIT ` + strconv.Itoa(trackPageSize) + ` OFFSET $9)
ORDER BY ` + order
}

// trackPageTotalsQuery is how many tracks pass the page's filters, and the bounds a client sets
// the filters within, over every track of the account: the distances of those with a route,
// the first and last local dates, and the types.
var trackPageTotalsQuery = `
SELECT count(*) FILTER (WHERE ` + trackPageWhere + `),
       min(distance_meters::float8) FILTER (WHERE trajectory IS NOT NULL),
       max(distance_meters::float8) FILTER (WHERE trajectory IS NOT NULL),
       min(` + localStartedAt + `::date), max(` + localStartedAt + `::date),
       COALESCE(array_agg(DISTINCT track_type), '{}')
FROM tracks
WHERE user_id = $1`

// trackBounds are the filters' bounds over every track of the account, null where no track
// sets one.
type trackBounds struct {
	MinDistanceMeters *float64 `json:"min_distance_meters"`
	MaxDistanceMeters *float64 `json:"max_distance_meters"`
	FirstDate         *string  `json:"first_date"`
	LastDate          *string  `json:"last_date"`
	Types             []string `json:"types"`
}

type trackPageResponse struct {
	Tracks []trackRow `json:"tracks"`
	// Types describes the rows' types and every type in Bounds.
	Types    map[string]tracktype.Info `json:"types"`
	Page     int                       `json:"page"`
	PageSize int                       `json:"page_size"`
	Total    int                       `json:"total"`
	Bounds   trackBounds               `json:"bounds"`
}

// serveTrackPage answers `GET /v2/tracks?page=` (IMPLEMENTATION.md §4.7): one of Library's pages.
func (s *Server) serveTrackPage(w http.ResponseWriter, r *http.Request, f trackFilter, p trackPage) {
	resp, err := s.readTrackPage(r.Context(), f, p)
	if err != nil {
		if clientGone(w, r) {
			return
		}
		s.log.Error("track page query failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	slices.Sort(resp.Bounds.Types)
	types := slices.Clone(resp.Bounds.Types)
	for _, a := range resp.Tracks {
		types = append(types, a.TrackType)
	}
	resp.Types = tracktype.Describe(types, requestLang(r))
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, resp)
}

// readTrackPage reads the page's rows and its totals in one snapshot, so `total` counts the
// same tracks the rows were read from.
func (s *Server) readTrackPage(ctx context.Context, f trackFilter, p trackPage) (trackPageResponse, error) {
	resp := trackPageResponse{Page: p.Page, PageSize: trackPageSize}
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return resp, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck // read-only, nothing to keep
	args := []any{userIDFromContext(ctx), f.From, f.To, f.Types, f.Trip, p.Search, p.MinDistance, p.MaxDistance}
	rows, err := tx.Query(ctx, trackPageQuery(p.Sort, p.Desc), append(args, p.offset())...)
	if err != nil {
		return resp, err
	}
	resp.Tracks, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (trackRow, error) { return scanTrackRow(row) })
	if err != nil {
		return resp, err
	}
	var first, last *time.Time
	if err := tx.QueryRow(ctx, trackPageTotalsQuery, args...).Scan(&resp.Total,
		&resp.Bounds.MinDistanceMeters, &resp.Bounds.MaxDistanceMeters, &first, &last, &resp.Bounds.Types); err != nil {
		return resp, err
	}
	resp.Bounds.FirstDate, resp.Bounds.LastDate = optionalDate(first), optionalDate(last)
	return resp, nil
}

// optionalDate is a ::date column as YYYY-MM-DD, nil for NULL.
func optionalDate(t *time.Time) *string {
	if t == nil {
		return nil
	}
	v := t.Format(dateLayout)
	return &v
}
