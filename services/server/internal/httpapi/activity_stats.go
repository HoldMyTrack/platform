package httpapi

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"strconv"
	"time"
)

// activitySummaryQuery is §4.7's range summary: one query, one row, the aggregate behind
// the panel's own "1,284 km · 186 activities · 42 h · 9,120 m up" line. Same filter shape as
// the list above, deliberately — the totals have to describe exactly the set of activities
// the list is showing, which only holds if both read the same filter.
//
// COALESCE to 0 here, unlike the per-row nullability the list preserves: SUM already skips
// NULL inputs, and a total over zero rows is legitimately zero rather than unknown. The
// distinction that matters is between "this activity recorded no distance" (a row value,
// null) and "these activities add up to nothing" (a total, 0).
var activitySummaryQuery = `
SELECT COUNT(*),
       COALESCE(SUM(distance_meters), 0),
       COALESCE(SUM(duration_seconds), 0),
       COALESCE(SUM(elevation_gain_m), 0)
FROM activities
WHERE user_id = $1
  AND ` + inDateRange("$2", "$3") + `
  AND ($4::text[] IS NULL OR activity_type = ANY($4))
  AND ($5::uuid IS NULL OR activities.id IN (SELECT activity_id FROM story_activities WHERE story_id = $5))`

type activitySummaryResponse struct {
	Count           int64   `json:"count"`
	DistanceMeters  float64 `json:"distance_meters"`
	DurationSeconds int64   `json:"duration_seconds"`
	ElevationGainM  float64 `json:"elevation_gain_m"`
}

// handleActivitySummary serves §4.7's `GET /v1/activities/summary`. No cursor and no rows:
// the whole point is that a client showing totals doesn't have to page through the history
// to add them up itself.
func (s *Server) handleActivitySummary(w http.ResponseWriter, r *http.Request) {
	filter, err := parseActivityFilter(r.URL.Query())
	if err != nil {
		writeAPIError(w, err.Error(), http.StatusBadRequest)
		return
	}

	var resp activitySummaryResponse
	if err := s.pool.QueryRow(r.Context(), activitySummaryQuery,
		userIDFromContext(r.Context()), filter.From, filter.To, filter.Types, filter.Story,
	).Scan(&resp.Count, &resp.DistanceMeters, &resp.DurationSeconds, &resp.ElevationGainM); err != nil {
		s.log.Error("activity summary query failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, resp)
}

// histogramWindowMonths is the *default* window length for the calendar-window mode, used
// when a caller sends no `days` and no `from`/`to`. Twelve months is what the original
// fixed-window mockup's Jan–Nov axis implied, and is still a reasonable first paint for a
// caller that has nothing else to go on — §4.8's year-grid activity graph is the one that
// still wants whole calendar windows.
const histogramWindowMonths = 12

// maxHistogramDays bounds the activity-day mode's LIMIT. A page is meant to be one strip of
// bars, not a whole history in one request, and an unbounded `days=` is an unbounded LIMIT.
const maxHistogramDays = 366

// activityHistogramQuery is §4.7's per-bucket aggregate over a calendar window.
// Deliberately unfiltered beyond the window, the user and the optional Story ($5): this chart
// is the backdrop a selected sub-range is highlighted against, so narrowing it by the same
// type filter as the list would defeat its purpose. A Story is different — inside one, the
// picker's whole world is the Story's activities (§4.23).
//
// Days with no activity are simply absent from the result rather than returned as zeroes —
// GROUP BY produces no row for them, and a client that has the window's start and end can
// place what it did get. That keeps the response proportional to how much a user actually
// recorded rather than to how long the window is.
//
// The bucket is each activity's own local day (localStartedAt, §4.30), and the window
// [$2, $3) is in local dates too.
const activityHistogramQuery = `
SELECT ` + localStartedAt + `::date AS day,
       COUNT(*),
       COALESCE(SUM(distance_meters), 0)
FROM activities
WHERE user_id = $1
  AND ` + localStartedAt + ` >= $2::date
  AND ` + localStartedAt + ` < $3::date
  AND ($4::uuid IS NULL OR activities.id IN (SELECT activity_id FROM story_activities WHERE story_id = $4))
GROUP BY day
ORDER BY day`

// activityDayPageQuery is the same aggregate paginated by *activity-day* rather than by
// calendar range: the `days` most recent distinct days-with-activity, optionally restricted
// to those strictly before some day. It exists because the date slider has one slot per
// day-with-activity with the empty days removed entirely (apps/web/src/ui/DateRangeSlider.tsx,
// and the Android app's footer), so "one window of days" is a count of real days, not a width
// of calendar time. Asking for that with a calendar window would mean the client guessing a
// window and widening it until enough days came back — several round trips per page over a
// sparse history, and a guess that is wrong in a different direction for every user. One page
// here is exactly `days` days, every time.
//
// The anchor is a local date like the days themselves, so each activity is compared in its
// own zone; the account's live activities are read through idx_activities_live either way.
const activityDayPageQuery = `
SELECT ` + localStartedAt + `::date AS day,
       COUNT(*),
       COALESCE(SUM(distance_meters), 0)
FROM activities
WHERE user_id = $1
  AND ($2::date IS NULL OR ` + localStartedAt + ` < $2::date)
  AND ($4::uuid IS NULL OR activities.id IN (SELECT activity_id FROM story_activities WHERE story_id = $4))
GROUP BY day
ORDER BY day DESC
LIMIT $3`

type histogramBucket struct {
	Date           string  `json:"date"` // YYYY-MM-DD, the local day its activities happened on
	Count          int64   `json:"count"`
	DistanceMeters float64 `json:"distance_meters"`
}

type activityHistogramResponse struct {
	Bucket string `json:"bucket"` // "day"
	// The window the buckets came from, inclusive at both ends. In calendar-window mode it
	// is whatever was asked for, so a client can lay out the empty days in between; in
	// activity-day mode it is the first and last day the page actually returned, since the
	// page is defined by a bar count rather than by a window. Both are empty when a page
	// came back with nothing.
	From    string            `json:"from"`
	To      string            `json:"to"`
	Buckets []histogramBucket `json:"buckets"`
	// The local day of the account's very first activity, omitted when they have none. Not
	// bounded by From/To — it answers a different question ("how far back is there
	// anything at all") than the window does, so the client's date slider knows
	// when it has paged back as far as there is anything to page back to, however far
	// back `from` currently is.
	Earliest string `json:"earliest,omitempty"`
}

// handleActivityHistogram serves §4.7's `GET /v1/activities/histogram` in two modes, both
// returning the same body. The filter is deliberately not applied (no `types`) in either —
// this chart is the backdrop a selected sub-range highlights against, and narrowing it the
// same way as the list would defeat that. `story` is the exception: both modes, and
// `earliest`, then cover only that Story's activities, since inside a Story the picker spans
// the Story alone (§4.23).
//
//   - `?days=N[&before=YYYY-MM-DD]` — activity-day pagination: the N most recent distinct
//     days-with-activity, or the N most recent strictly before `before`. This is what the
//     range picker's strip pages through, one screen of bars per request.
//   - `?from=&to=` — a calendar window, both optional, defaulting to the trailing
//     histogramWindowMonths months. Still the endpoint's default behaviour, and still what
//     a caller laying days out against real elapsed time (§4.8's year grid) wants.
//
// There is no `after=` counterpart to `before=`: a client paging this way starts at the
// newest end and only ever walks backwards, so everything between its anchor and today is
// already in hand by construction.
func (s *Server) handleActivityHistogram(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	loc := locationFromContext(r.Context())
	story, err := parseStoryParam(q)
	if err != nil {
		writeAPIError(w, err.Error(), http.StatusBadRequest)
		return
	}

	var (
		buckets []histogramBucket
		from    string
		to      string
	)
	if q.Get("days") != "" {
		buckets, err = s.activityDayPage(r, q, story)
	} else {
		buckets, from, to, err = s.activityCalendarWindow(r, q, loc, story)
	}
	if err != nil {
		s.writeHistogramError(w, r, err)
		return
	}
	if q.Get("days") != "" && len(buckets) > 0 {
		from, to = buckets[0].Date, buckets[len(buckets)-1].Date
	}

	earliest, err := s.earliestActivity(r.Context(), userIDFromContext(r.Context()), story)
	if err != nil {
		if clientGone(w, r) {
			return
		}
		s.log.Error("activity earliest-date query failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}

	resp := activityHistogramResponse{Bucket: "day", From: from, To: to, Buckets: buckets}
	if earliest != nil {
		resp.Earliest = earliest.Format(dateLayout)
	}

	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, resp)
}

// earliestActivity is the local date the account's first activity started on — or the
// Story's, when story is set — nil when there is none: the histogram's `earliest`, and how far
// back the Profile page's year grids go. A date, at midnight UTC.
func (s *Server) earliestActivity(ctx context.Context, userID string, story *string) (*time.Time, error) {
	var earliest *time.Time
	err := s.pool.QueryRow(ctx,
		`SELECT MIN(`+localStartedAt+`)::date FROM activities
		 WHERE user_id = $1
		   AND ($2::uuid IS NULL OR activities.id IN (SELECT activity_id FROM story_activities WHERE story_id = $2))`,
		userID, story,
	).Scan(&earliest)
	return earliest, err
}

// dailyTotals is the histogram's calendar-window query for the local dates [first, end): one
// bucket per local day with activity, ascending, over one Story's activities when story is
// set — the JSON endpoint's `?from=&to=` mode and the Profile page's year grids both read it.
func (s *Server) dailyTotals(ctx context.Context, userID string, first, end time.Time, story *string) ([]histogramBucket, error) {
	return s.scanHistogramBuckets(ctx, activityHistogramQuery, userID, sqlDate(first), sqlDate(end), story)
}

// badRequest marks an error as the client's fault, so the two mode helpers can return plain
// errors and let one caller decide the status code.
type badRequest struct{ error }

func (s *Server) writeHistogramError(w http.ResponseWriter, r *http.Request, err error) {
	var bad badRequest
	if errors.As(err, &bad) {
		writeAPIError(w, bad.Error(), http.StatusBadRequest)
		return
	}
	if clientGone(w, r) {
		return
	}
	s.log.Error("activity histogram query failed", "err", err)
	writeAPIError(w, "internal error", http.StatusInternalServerError)
}

// activityDayPage is the `?days=N&before=` mode. Buckets come back newest-first from the
// LIMIT and are reversed here, so every response this endpoint sends is in ascending date
// order regardless of which mode produced it — a client should not have to check.
func (s *Server) activityDayPage(r *http.Request, q url.Values, story *string) ([]histogramBucket, error) {
	limit, before, err := parseDayPage(q)
	if err != nil {
		return nil, err
	}
	buckets, err := s.scanHistogramBuckets(r.Context(), activityDayPageQuery, userIDFromContext(r.Context()), before, limit, story)
	if err != nil {
		return nil, err
	}
	for i, j := 0, len(buckets)-1; i < j; i, j = i+1, j-1 {
		buckets[i], buckets[j] = buckets[j], buckets[i]
	}
	return buckets, nil
}

// parseDayPage reads the activity-day mode's `days`, capped at maxHistogramDays, and its
// optional `before` anchor, nil when absent so the query's "$2::date IS NULL OR …" applies.
func parseDayPage(q url.Values) (int, *string, error) {
	limit, err := strconv.Atoi(q.Get("days"))
	if err != nil || limit < 1 {
		return 0, nil, badRequest{errors.New(`invalid "days", want a positive integer`)}
	}
	limit = min(limit, maxHistogramDays)
	var before *string
	if v := q.Get("before"); v != "" {
		if _, err := time.Parse(dateLayout, v); err != nil {
			return 0, nil, badRequest{errors.New(`invalid "before" date, want YYYY-MM-DD`)}
		}
		before = &v
	}
	return limit, before, nil
}

// dateWindow is the calendar window a `from`/`to` query asks for, both inclusive local dates in
// loc: `to` defaults to today, `from` to histogramWindowMonths before `to`. The histogram's
// calendar mode and Trends share it.
func dateWindow(q url.Values, now time.Time, loc *time.Location) (first, last time.Time, err error) {
	now = now.In(loc)
	last = time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, loc)
	if v := q.Get("to"); v != "" {
		if last, err = time.ParseInLocation(dateLayout, v, loc); err != nil {
			return first, last, badRequest{errors.New(`invalid "to" date, want YYYY-MM-DD`)}
		}
	}
	first = last.AddDate(0, -histogramWindowMonths, 0)
	if v := q.Get("from"); v != "" {
		if first, err = time.ParseInLocation(dateLayout, v, loc); err != nil {
			return first, last, badRequest{errors.New(`invalid "from" date, want YYYY-MM-DD`)}
		}
	}
	if first.After(last) {
		return first, last, badRequest{errors.New(`"from" must not be after "to"`)}
	}
	return first, last, nil
}

// activityCalendarWindow is the `?from=&to=` mode: one bucket per day with activity in the
// window, and the window echoed back so the caller can lay out the days that have none.
func (s *Server) activityCalendarWindow(r *http.Request, q url.Values, loc *time.Location, story *string) ([]histogramBucket, string, string, error) {
	first, last, err := dateWindow(q, time.Now(), loc)
	if err != nil {
		return nil, "", "", err
	}
	end := last.AddDate(0, 0, 1) // exclusive upper bound for the query

	buckets, err := s.dailyTotals(r.Context(), userIDFromContext(r.Context()), first, end, story)
	if err != nil {
		return nil, "", "", err
	}
	return buckets, first.Format(dateLayout), last.Format(dateLayout), nil
}

// scanHistogramBuckets runs either histogram query — they return the same three columns in
// the same order, and differ only in how they choose which days to return.
func (s *Server) scanHistogramBuckets(ctx context.Context, query string, args ...any) ([]histogramBucket, error) {
	rows, err := s.pool.Query(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	buckets := make([]histogramBucket, 0)
	for rows.Next() {
		var day time.Time
		var b histogramBucket
		if err := rows.Scan(&day, &b.Count, &b.DistanceMeters); err != nil {
			return nil, err
		}
		b.Date = day.Format(dateLayout)
		buckets = append(buckets, b)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return buckets, nil
}

// activityStatsAggregateQuery is count/distance/active-days over an optional [from, to) window
// — the same three numbers activitySummaryQuery above already computes, minus the `types`
// filter §4.8's graph has no use for (the grid and its cards describe a whole year, not a
// narrowed view of one), plus active-days, which nothing existing exposes as a single number:
// a caller wanting it today would have to count histogram buckets itself.
const activityStatsAggregateQuery = `
SELECT COUNT(*),
       COALESCE(SUM(distance_meters), 0),
       COUNT(DISTINCT ` + localStartedAt + `::date)
FROM activities
WHERE user_id = $1
  AND ($2::date IS NULL OR ` + localStartedAt + ` >= $2::date)
  AND ($3::date IS NULL OR ` + localStartedAt + ` < $3::date)`

// activityLongestStreakQuery finds the longest run of consecutive calendar days with at least
// one activity, over the same optional window — a classic gaps-and-islands query, not
// something any existing query here computes. `day` minus its own row number (as whole days)
// is constant across a run of consecutive dates and changes at every gap, so grouping by that
// expression groups exactly the consecutive runs; the largest group is the longest streak.
const activityLongestStreakQuery = `
WITH days AS (
  SELECT DISTINCT ` + localStartedAt + `::date AS day
  FROM activities
  WHERE user_id = $1
    AND ($2::date IS NULL OR ` + localStartedAt + ` >= $2::date)
    AND ($3::date IS NULL OR ` + localStartedAt + ` < $3::date)
),
islands AS (
  SELECT day - (ROW_NUMBER() OVER (ORDER BY day))::int * INTERVAL '1 day' AS run
  FROM days
)
SELECT COALESCE(MAX(run_length), 0)
FROM (SELECT COUNT(*) AS run_length FROM islands GROUP BY run) AS runs`

// activityStatsBlock is one of §4.8's two stat-card rows (a selected year, or all-time) — the
// same four numbers repeat under each year's grid and again as the page's
// all-time header cards.
type activityStatsBlock struct {
	Count             int64   `json:"count"`
	DistanceMeters    float64 `json:"distance_meters"`
	ActiveDays        int64   `json:"active_days"`
	LongestStreakDays int64   `json:"longest_streak_days"`
}

// activityStats runs both queries above for one optional [from, to) window. Two round trips
// rather than one combined query: the aggregate is a plain GROUP-BY-free scan and the streak
// needs its own CTE, and combining them into one query would mean computing the window twice
// anyway (once per CTE) for no fewer round trips saved, since both still have to run to
// completion before a single response can be built either way.
func (s *Server) activityStats(ctx context.Context, userID string, from, to *string) (activityStatsBlock, error) {
	var b activityStatsBlock
	if err := s.pool.QueryRow(ctx, activityStatsAggregateQuery, userID, from, to).
		Scan(&b.Count, &b.DistanceMeters, &b.ActiveDays); err != nil {
		return activityStatsBlock{}, err
	}
	if err := s.pool.QueryRow(ctx, activityLongestStreakQuery, userID, from, to).
		Scan(&b.LongestStreakDays); err != nil {
		return activityStatsBlock{}, err
	}
	return b, nil
}

type activityGraphStatsResponse struct {
	Year int `json:"year"`
	// The requested calendar year's own numbers — repeated under each year's
	// grid.
	YearStats activityStatsBlock `json:"year_stats"`
	// Every activity ever recorded, regardless of year — the page's own header cards.
	AllTime activityStatsBlock `json:"all_time"`
}

// graphStatsYear is the `year` asked for, or now's when there is none.
func graphStatsYear(q url.Values, now time.Time) (int, error) {
	v := q.Get("year")
	if v == "" {
		return now.Year(), nil
	}
	y, err := strconv.Atoi(v)
	if err != nil || y < 1 {
		return 0, errors.New(`invalid "year", want a 4-digit year`)
	}
	return y, nil
}

// handleActivityGraphStats serves §4.8's `GET /v1/activities/graph-stats?year=YYYY`: the four
// stat-card numbers (count, distance, active days, longest streak) for one calendar year and
// for all time. The grid's cells themselves need no new endpoint — they are exactly
// handleActivityHistogram's existing `?from=&to=` calendar-window mode, year-scoped
// (`?from=YYYY-01-01&to=YYYY-12-31`), which already returns per-day count/distance buckets and
// this user's earliest activity date for bounding the year switcher.
//
// `year` defaults to the account's own current local year when omitted, so a bare request
// from the graph's first paint (before it knows what to ask for) still gets something
// sensible back.
func (s *Server) handleActivityGraphStats(w http.ResponseWriter, r *http.Request) {
	year, err := graphStatsYear(r.URL.Query(), time.Now().In(locationFromContext(r.Context())))
	if err != nil {
		writeAPIError(w, err.Error(), http.StatusBadRequest)
		return
	}

	yearStart := sqlDate(time.Date(year, time.January, 1, 0, 0, 0, 0, time.UTC))
	yearEnd := sqlDate(time.Date(year+1, time.January, 1, 0, 0, 0, 0, time.UTC))
	userID := userIDFromContext(r.Context())

	yearStats, err := s.activityStats(r.Context(), userID, &yearStart, &yearEnd)
	if err != nil {
		s.log.Error("activity year-stats query failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	allTime, err := s.activityStats(r.Context(), userID, nil, nil)
	if err != nil {
		s.log.Error("activity all-time-stats query failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, activityGraphStatsResponse{Year: year, YearStats: yearStats, AllTime: allTime})
}

// activityTrendsQuery is docs/SPEC.md FR-9's "trends": count/distance/moving-time/
// elevation-gain per calendar bucket (week or month), over the [from, to) window. Every bucket
// the window touches comes back, an empty one as zeroes: generate_series lists them from the
// bucket holding $3 to the one holding the day before $4, and the account's sums are left-joined
// onto that list, so a chart drawn one bar per period spans the whole window.
// $1 (the bucket) is a bound parameter, not string-interpolated — date_trunc accepts its
// first argument as a plain value, so this is not an injection vector — but the handler
// still validates it against an allow-list first, so a bad value gets a clean 400 instead
// of a Postgres error.
//
// moving_seconds falls back to duration_seconds per row: ingest.Process only started
// populating moving_seconds once the movingS-from-stopped-time fix landed, so activities
// ingested before that have NULL there — COALESCE keeps old and new activities rendering
// consistently in the same trend line rather than silently undercounting older periods.
const activityTrendsQuery = `
WITH sums AS (
  SELECT date_trunc($1::text, ` + localStartedAt + `)::date AS period,
         COUNT(*) AS count,
         COALESCE(SUM(distance_meters), 0) AS distance,
         COALESCE(SUM(COALESCE(moving_seconds, duration_seconds)), 0) AS moving,
         COALESCE(SUM(elevation_gain_m), 0) AS gain
  FROM activities
  WHERE user_id = $2
    AND ` + localStartedAt + ` >= $3::date
    AND ` + localStartedAt + ` < $4::date
  GROUP BY period
)
SELECT b.ts::date, COALESCE(s.count, 0), COALESCE(s.distance, 0), COALESCE(s.moving, 0), COALESCE(s.gain, 0)
FROM generate_series(date_trunc($1::text, $3::date::timestamp),
                     date_trunc($1::text, ($4::date - 1)::timestamp),
                     ('1 ' || $1::text)::interval) AS b(ts)
LEFT JOIN sums s ON s.period = b.ts::date
ORDER BY b.ts`

type trendPeriod struct {
	PeriodStart    string  `json:"period_start"` // YYYY-MM-DD, the bucket's own start day
	Count          int64   `json:"count"`
	DistanceMeters float64 `json:"distance_meters"`
	MovingSeconds  int64   `json:"moving_seconds"`
	ElevationGainM float64 `json:"elevation_gain_m"`
}

type activityTrendsResponse struct {
	Bucket  string        `json:"bucket"` // "week" or "month"
	From    string        `json:"from"`
	To      string        `json:"to"`
	Periods []trendPeriod `json:"periods"`
}

// activityTrends runs activityTrendsQuery for the local dates [first, end) — the JSON endpoint
// below and the Profile page's Trends chart both read it. bucket must already be "week" or
// "month".
func (s *Server) activityTrends(ctx context.Context, userID, bucket string, first, end time.Time) ([]trendPeriod, error) {
	rows, err := s.pool.Query(ctx, activityTrendsQuery, bucket, userID, sqlDate(first), sqlDate(end))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	periods := make([]trendPeriod, 0)
	for rows.Next() {
		var period time.Time
		var p trendPeriod
		if err := rows.Scan(&period, &p.Count, &p.DistanceMeters, &p.MovingSeconds, &p.ElevationGainM); err != nil {
			return nil, err
		}
		p.PeriodStart = period.Format(dateLayout)
		periods = append(periods, p)
	}
	return periods, rows.Err()
}

// trendBucket is the `bucket` asked for, "week" when there is none.
func trendBucket(q url.Values) (string, error) {
	switch b := q.Get("bucket"); b {
	case "":
		return "week", nil
	case "week", "month":
		return b, nil
	}
	return "", errors.New(`invalid "bucket", want "week" or "month"`)
}

// handleActivityTrends serves `GET /v1/activities/trends?bucket=week|month&from=&to=`.
// `from`/`to` default to the trailing histogramWindowMonths months, the same default the
// calendar-window histogram mode already uses — there's no reason a trend line's default
// window should be a different length than the graph's.
func (s *Server) handleActivityTrends(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	bucket, err := trendBucket(q)
	if err != nil {
		writeAPIError(w, err.Error(), http.StatusBadRequest)
		return
	}
	first, last, err := dateWindow(q, time.Now(), locationFromContext(r.Context()))
	if err != nil {
		writeAPIError(w, err.Error(), http.StatusBadRequest)
		return
	}
	end := last.AddDate(0, 0, 1) // exclusive upper bound, matching activityCalendarWindow

	periods, err := s.activityTrends(r.Context(), userIDFromContext(r.Context()), bucket, first, end)
	if err != nil {
		s.log.Error("activity trends query failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, activityTrendsResponse{
		Bucket:  bucket,
		From:    first.Format(dateLayout),
		To:      last.Format(dateLayout),
		Periods: periods,
	})
}
