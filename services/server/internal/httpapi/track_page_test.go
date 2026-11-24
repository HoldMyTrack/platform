package httpapi

// Covers docs/SPEC.md FR-17.1 (Library's pages).

import (
	"context"
	"net/http"
	"slices"
	"strings"
	"testing"
	"time"
)

func TestParseTrackPage(t *testing.T) {
	if _, paged, err := parseTrackPage(query(t, "")); paged || err != nil {
		t.Fatalf("no page: paged %v, %v", paged, err)
	}
	p, paged, err := parseTrackPage(query(t, "page=1"))
	if !paged || err != nil || p.Page != 1 || p.Sort != "started" || !p.Desc || p.Search != nil || p.MinDistance != nil || p.MaxDistance != nil {
		t.Fatalf("defaults: %+v %v %v", p, paged, err)
	}
	if p.offset() != 0 {
		t.Errorf("page 1 offset %d", p.offset())
	}
	p, _, err = parseTrackPage(query(t, "page=3&sort=distance_asc&q=++Café+&min_distance=1000&max_distance=5000.5"))
	if err != nil || p.offset() != 200 || p.Sort != "distance" || p.Desc || *p.Search != "Café" || *p.MinDistance != 1000 || *p.MaxDistance != 5000.5 {
		t.Fatalf("full: %+v %v", p, err)
	}
	if p, _, err := parseTrackPage(query(t, "page=1&q=+++")); err != nil || p.Search != nil {
		t.Errorf("blank search: %+v %v", p, err)
	}
	if p, _, err := parseTrackPage(query(t, "page=1&max_distance=0")); err != nil || p.MinDistance != nil || *p.MaxDistance != 0 {
		t.Errorf("max only: %+v %v", p, err)
	}
	// An empty value is no value, paged or not.
	if _, paged, err := parseTrackPage(query(t, "q=&sort=&min_distance=")); paged || err != nil {
		t.Errorf("empty values without page: paged %v, %v", paged, err)
	}
	for _, bad := range []string{
		"page=1&q=%FF", "page=1&q=a%00b", "page=1&max_distance=1e10",
		"sort=distance_asc", "q=x", "min_distance=1", "max_distance=1",
		"page=0", "page=-1", "page=x", "page=1000001",
		"page=1&sort=distance", "page=1&sort=name_asc", "page=1&sort=started_up",
		"page=1&min_distance=-1", "page=1&max_distance=far", "page=1&min_distance=10&max_distance=5",
		"page=1&q=" + strings.Repeat("a", maxTrackSearchLen+1),
	} {
		if _, _, err := parseTrackPage(query(t, bad)); err == nil {
			t.Errorf("%s: parsed, want refused", bad)
		}
	}
}

func TestTrackPage(t *testing.T) {
	d := newDBTest(t)
	me, other := d.newAccount(false), d.newAccount(false)
	here := [2]float64{-81.60, 41.30}
	day := func(n int) time.Time { return time.Date(2026, 5, n, 12, 0, 0, 0, time.UTC) }
	ctx := context.Background()
	named := func(id, name, description string, added time.Time) {
		t.Helper()
		if _, err := d.pool.Exec(ctx, `UPDATE tracks SET name = NULLIF($2, ''), description = NULLIF($3, ''), created_at = $4 WHERE id = $1`,
			id, name, description, added); err != nil {
			t.Fatal(err)
		}
	}
	moving := func(s int) *int { return &s }
	short := d.newTrack(me, testTrack{trackType: "walking", distanceMeters: 1000, movingSeconds: moving(900), durationSecs: 1000, at: &here, startedAt: day(1)})
	long := d.newTrack(me, testTrack{trackType: "cycling", distanceMeters: 40000, movingSeconds: moving(5000), durationSecs: 6000, at: &here, startedAt: day(2)})
	mid := d.newTrack(me, testTrack{trackType: "walking", distanceMeters: 5000, movingSeconds: moving(3000), durationSecs: 3000, at: &here, startedAt: day(3)})
	private := d.newTrack(me, testTrack{trackType: "walking", distanceMeters: 2000, durationSecs: 1200, startedAt: day(4)})
	d.newTrack(other, testTrack{trackType: "running", distanceMeters: 7000, durationSecs: 2000, at: &here, startedAt: day(5)})
	named(short, "Morning café", "", day(20))
	named(long, "", "Lap around Müggelsee", day(10))
	named(mid, "Cafeteria run", "", day(30))
	named(private, "", "", day(5))

	page := func(q string) trackPageResponse {
		t.Helper()
		var resp trackPageResponse
		d.decode(d.do(me, "GET", "/v2/tracks?page=1&"+q, nil), http.StatusOK, &resp)
		return resp
	}
	ids := func(resp trackPageResponse) []string {
		out := []string{}
		for _, a := range resp.Tracks {
			out = append(out, a.ID)
		}
		return out
	}
	for _, tc := range []struct {
		query string
		want  []string
	}{
		{"", []string{private, mid, long, short}},
		{"sort=started_asc", []string{short, long, mid, private}},
		{"sort=added_desc", []string{mid, short, long, private}},
		// A track with no route has no distance or moving time, and sorts last both ways.
		{"sort=distance_desc", []string{long, mid, short, private}},
		{"sort=distance_asc", []string{short, mid, long, private}},
		{"sort=moving_asc", []string{short, mid, long, private}},
		// Case and accents are ignored; an unnamed track matches by its description.
		{"q=CAFE", []string{mid, short}},
		{"q=café", []string{mid, short}},
		{"q=muggel", []string{long}},
		{"q=nothing", []string{}},
		// A Distance bound leaves out the track with no route, whatever its stored distance.
		{"min_distance=1500", []string{mid, long}},
		{"max_distance=5000", []string{mid, short}},
		{"min_distance=0", []string{mid, long, short}},
		{"types=walking&q=caf", []string{mid, short}},
		{"from=2026-05-02&to=2026-05-03", []string{mid, long}},
	} {
		if got := ids(page(tc.query)); !slices.Equal(got, tc.want) {
			t.Errorf("?%s = %v, want %v", tc.query, got, tc.want)
		}
	}

	resp := page("q=caf")
	if resp.Page != 1 || resp.PageSize != trackPageSize || resp.Total != 2 {
		t.Errorf("page %d of %d, total %d", resp.Page, resp.PageSize, resp.Total)
	}
	// Bounds cover every track, whatever the filters, and a track with no route sets no distance.
	b := resp.Bounds
	if *b.MinDistanceMeters != 1000 || *b.MaxDistanceMeters != 40000 || *b.FirstDate != "2026-05-01" || *b.LastDate != "2026-05-04" ||
		!slices.Equal(b.Types, []typeCount{{"walking", 3}, {"cycling", 1}}) {
		t.Errorf("bounds %+v", b)
	}
	if resp.Tracks[0].AddedAt.IsZero() {
		t.Error("want each row's added_at")
	}
	if _, ok := resp.Types["cycling"]; !ok {
		t.Errorf("types %v: want every type in bounds described", resp.Types)
	}

	var past trackPageResponse
	d.decode(d.do(me, "GET", "/v2/tracks?page=2", nil), http.StatusOK, &past)
	if len(past.Tracks) != 0 || past.Total != 4 {
		t.Errorf("past the last page: %d rows, total %d", len(past.Tracks), past.Total)
	}

	var empty trackPageResponse
	d.decode(d.do(d.newAccount(false), "GET", "/v2/tracks?page=1", nil), http.StatusOK, &empty)
	if empty.Total != 0 || empty.Bounds.FirstDate != nil || empty.Bounds.MinDistanceMeters != nil || len(empty.Bounds.Types) != 0 {
		t.Errorf("no tracks: %+v", empty)
	}

	d.decode(d.do(me, "GET", "/v2/tracks?sort=distance_asc", nil), http.StatusBadRequest, nil)
}

// Pages split the order without a gap or a repeat, ties broken by id.
func TestTrackPageSplitsTheOrder(t *testing.T) {
	d := newDBTest(t)
	me := d.newAccount(false)
	at := time.Date(2026, 5, 1, 12, 0, 0, 0, time.UTC)
	for range trackPageSize + 5 {
		d.newTrack(me, testTrack{trackType: "walking", distanceMeters: 1000, durationSecs: 600, startedAt: at})
	}
	seen := map[string]bool{}
	for n, want := range []int{trackPageSize, 5} {
		var resp trackPageResponse
		d.decode(d.do(me, "GET", "/v2/tracks?page="+string(rune('1'+n)), nil), http.StatusOK, &resp)
		if len(resp.Tracks) != want || resp.Total != trackPageSize+5 {
			t.Fatalf("page %d: %d rows, total %d", n+1, len(resp.Tracks), resp.Total)
		}
		for _, a := range resp.Tracks {
			if seen[a.ID] {
				t.Fatalf("page %d repeats %s", n+1, a.ID)
			}
			seen[a.ID] = true
		}
	}
}
