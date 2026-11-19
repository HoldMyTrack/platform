package httpapi

// Covers docs/SPEC.md FR-13.4 (the trip filter).

import (
	"context"
	"fmt"
	"net/http"
	"slices"
	"testing"
	"time"

	"github.com/HoldMyTrack/platform/services/server/internal/tilemath/tilemathtest"
)

// `trip` narrows the track list, the summary, the histogram (both modes and `earliest`)
// and the tracks tiles to one Trip's tracks, alongside the filters they already take.
func TestTripFilter(t *testing.T) {
	d := newDBTest(t)
	me, other := d.newAccount(false), d.newAccount(false)
	here := [2]float64{-81.60, 41.30}
	elsewhere := [2]float64{-81.20, 41.10}
	walk := d.newTrack(me, testTrack{trackType: "walking", distanceMeters: 3000, durationSecs: 1800, at: &here,
		startedAt: time.Date(2026, 5, 1, 12, 0, 0, 0, time.UTC)})
	outside := d.newTrack(me, testTrack{trackType: "walking", distanceMeters: 1000, durationSecs: 600, at: &elsewhere,
		startedAt: time.Date(2026, 5, 2, 12, 0, 0, 0, time.UTC)})
	drive := d.newTrack(me, testTrack{trackType: "driving", distanceMeters: 40000, durationSecs: 2400, at: &here,
		startedAt: time.Date(2026, 5, 3, 12, 0, 0, 0, time.UTC)})
	theirs := d.newTrack(other, testTrack{trackType: "walking", distanceMeters: 500, durationSecs: 300, at: &here,
		startedAt: time.Date(2026, 5, 1, 12, 0, 0, 0, time.UTC)})

	var trip, empty, theirTrip trip
	d.decode(d.do(me, "POST", "/v2/trips", map[string]any{"name": "Trip", "track_ids": []string{walk, drive}}), http.StatusCreated, &trip)
	d.decode(d.do(me, "POST", "/v2/trips", map[string]any{"name": "Empty"}), http.StatusCreated, &empty)
	d.decode(d.do(other, "POST", "/v2/trips", map[string]any{"name": "Theirs", "track_ids": []string{theirs}}), http.StatusCreated, &theirTrip)

	list := func(query string) []string {
		t.Helper()
		var resp tracksResponse
		d.decode(d.do(me, "GET", "/v2/tracks?"+query, nil), http.StatusOK, &resp)
		ids := []string{}
		for _, a := range resp.Tracks {
			ids = append(ids, a.ID)
		}
		return ids
	}
	for _, tc := range []struct {
		query string
		want  []string
	}{
		{"", []string{drive, outside, walk}},
		{"trip=" + trip.ID, []string{drive, walk}},
		{"trip=" + trip.ID + "&types=walking", []string{walk}},
		{"trip=" + trip.ID + "&from=2026-05-02&to=2026-05-03", []string{drive}},
		{"trip=" + empty.ID, []string{}},
		{"trip=" + theirTrip.ID, []string{}},
	} {
		if got := list(tc.query); !slices.Equal(got, tc.want) {
			t.Errorf("list ?%s = %v, want %v", tc.query, got, tc.want)
		}
	}

	var summary trackSummaryResponse
	d.decode(d.do(me, "GET", "/v2/tracks/summary?trip="+trip.ID, nil), http.StatusOK, &summary)
	if summary.Count != 2 || summary.DistanceMeters != 43000 {
		t.Errorf("summary %+v, want the Trip's two tracks", summary)
	}

	days := func(query string) ([]string, string) {
		t.Helper()
		var resp trackHistogramResponse
		d.decode(d.do(me, "GET", "/v2/tracks/histogram?"+query, nil), http.StatusOK, &resp)
		out := []string{}
		for _, b := range resp.Buckets {
			out = append(out, b.Date)
		}
		return out, resp.Earliest
	}
	for _, tc := range []struct {
		query, earliest string
		want            []string
	}{
		{"days=10", "2026-05-01", []string{"2026-05-01", "2026-05-02", "2026-05-03"}},
		{"days=10&trip=" + trip.ID, "2026-05-01", []string{"2026-05-01", "2026-05-03"}},
		{"days=10&before=2026-05-03&trip=" + trip.ID, "2026-05-01", []string{"2026-05-01"}},
		{"from=2026-05-01&to=2026-05-31&trip=" + trip.ID, "2026-05-01", []string{"2026-05-01", "2026-05-03"}},
		{"days=10&trip=" + empty.ID, "", []string{}},
		{"days=10&trip=" + theirTrip.ID, "", []string{}},
	} {
		got, earliest := days(tc.query)
		if !slices.Equal(got, tc.want) || earliest != tc.earliest {
			t.Errorf("histogram ?%s = %v earliest %q, want %v earliest %q", tc.query, got, earliest, tc.want, tc.earliest)
		}
	}

	const z = 12
	tile := func(at [2]float64, query string) int {
		t.Helper()
		x, y := tilemathtest.LonLatToTile(at[0], at[1], z)
		rec := d.do(me, "GET", fmt.Sprintf("/tiles/v1/tracks/%d/%d/%d.mvt?%s", z, x, y, query), nil)
		d.decode(rec, http.StatusOK, nil)
		return rec.Body.Len()
	}
	if tile(here, "trip="+trip.ID) == 0 {
		t.Errorf("the Trip's tile is empty")
	}
	if tile(elsewhere, "") == 0 {
		t.Errorf("the unfiltered tile elsewhere is empty")
	}
	for _, query := range []string{"trip=" + trip.ID, "trip=" + empty.ID} {
		if n := tile(elsewhere, query); n != 0 {
			t.Errorf("tile elsewhere ?%s has %d bytes; nothing there is in the Trip", query, n)
		}
	}
	// Their Trip's track is right here, but it isn't mine to draw.
	if n := tile(here, "trip="+theirTrip.ID); n != 0 {
		t.Errorf("another account's Trip drew %d bytes", n)
	}

	for _, path := range []string{"/v2/tracks", "/v2/tracks/summary", "/v2/tracks/histogram?days=5&", "/tiles/v1/tracks/12/0/0.mvt"} {
		sep := "?"
		if path[len(path)-1] == '&' {
			sep = ""
		}
		if rec := d.do(me, "GET", path+sep+"trip=nope", nil); rec.Code != http.StatusBadRequest {
			t.Errorf("%s with a malformed trip: status %d, want 400", path, rec.Code)
		}
	}
}

// A change to which tracks a Trip holds bumps the account's tile version, since the
// tracks tiles take a `trip` filter; anything else about a Trip doesn't.
func TestTripMembershipBumpsTileVersion(t *testing.T) {
	d := newDBTest(t)
	me := d.newAccount(false)
	a := d.newTrack(me, testTrack{trackType: "walking", durationSecs: 60})
	b := d.newTrack(me, testTrack{trackType: "walking", durationSecs: 60})
	version := func() int64 {
		t.Helper()
		var v int64
		if err := d.pool.QueryRow(context.Background(), `SELECT map_version FROM users WHERE id = $1`, me.id).Scan(&v); err != nil {
			t.Fatal(err)
		}
		return v
	}

	var empty, st trip
	steps := []struct {
		name   string
		bumps  bool
		method string
		path   func() string
		body   any
		status int
		out    *trip
	}{
		{"create empty", false, "POST", func() string { return "/v2/trips" }, map[string]any{"name": "Empty"}, http.StatusCreated, &empty},
		{"create with a track", true, "POST", func() string { return "/v2/trips" }, map[string]any{"name": "Trip", "track_ids": []string{a}}, http.StatusCreated, &st},
		{"rename", false, "PATCH", func() string { return "/v2/trips/" + st.ID }, map[string]any{"name": "Renamed", "description": "New"}, http.StatusOK, nil},
		{"add a member again", false, "POST", func() string { return "/v2/trips/" + st.ID + "/tracks" }, map[string]any{"track_ids": []string{a}}, http.StatusOK, nil},
		{"add", true, "POST", func() string { return "/v2/trips/" + st.ID + "/tracks" }, map[string]any{"track_ids": []string{b}}, http.StatusOK, nil},
		{"remove a non-member", false, "DELETE", func() string { return "/v2/trips/" + empty.ID + "/tracks" }, map[string]any{"track_ids": []string{a}}, http.StatusOK, nil},
		{"remove", true, "DELETE", func() string { return "/v2/trips/" + st.ID + "/tracks" }, map[string]any{"track_ids": []string{b}}, http.StatusOK, nil},
		{"delete an empty Trip", false, "DELETE", func() string { return "/v2/trips/" + empty.ID }, nil, http.StatusNoContent, nil},
		{"delete a Trip with tracks", true, "DELETE", func() string { return "/v2/trips/" + st.ID }, nil, http.StatusNoContent, nil},
	}
	for _, step := range steps {
		before := version()
		var out any
		if step.out != nil {
			out = step.out
		}
		d.decode(d.do(me, step.method, step.path(), step.body), step.status, out)
		if got := version() - before; (got > 0) != step.bumps {
			t.Errorf("%s: tile version moved by %d, want a bump: %v", step.name, got, step.bumps)
		}
	}
}
