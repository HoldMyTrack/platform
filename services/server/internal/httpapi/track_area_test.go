package httpapi

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"slices"
	"testing"
	"time"

	"github.com/HoldMyTrack/platform/services/server/internal/tilemath/tilemathtest"
)

// The area list (FR-5.11): the tracks crossing a view, newest first, capped with the area's
// total, across the antimeridian either way round, in slim rows.
func TestListArea(t *testing.T) {
	d := newDBTest(t)
	me := d.newAccount(false)
	ctx := context.Background()
	day := func(n int) time.Time { return time.Date(2026, 5, n, 10, 0, 0, 0, time.UTC) }
	track := func(started time.Time, wkt string) string {
		id := d.newTrack(me, testTrack{trackType: "hiking", startedAt: started, at: &[2]float64{0, 0}})
		if _, err := d.pool.Exec(ctx, `UPDATE tracks SET trajectory = ST_GeomFromText($2, 4326) WHERE id = $1`, id, wkt); err != nil {
			t.Fatal(err)
		}
		return id
	}
	older := d.newTrack(me, testTrack{trackType: "hiking", startedAt: day(1), at: &[2]float64{-30.6, -30.6}})
	newer := d.newTrack(me, testTrack{trackType: "running", startedAt: day(2), at: &[2]float64{-30.4, -30.4}})
	d.newTrack(me, testTrack{trackType: "hiking", startedAt: day(3), at: &[2]float64{-20.5, -30.5}}) // outside
	d.newTrack(me, testTrack{trackType: "hiking", startedAt: day(4)})                                // no track (FR-7.1)
	// Its box covers the view, but the line goes round it.
	track(day(5), "LINESTRING M(-32 -29.5 0, -29.5 -29.5 60, -29.5 -32 120)")
	// Stored continuing past 180 (§4.1), as ingest keeps a track across the antimeridian.
	dateline := track(day(6), "LINESTRING M(179.9 -40.5 0, 180.1 -40.4 60)")

	type listed struct {
		ids   []string
		total *int
	}
	get := func(query string) listed {
		t.Helper()
		var resp areaResponse
		d.decode(d.do(me, "GET", "/v2/tracks/area?"+query, nil), http.StatusOK, &resp)
		var ids []string
		for _, a := range resp.Tracks {
			ids = append(ids, a.ID)
		}
		return listed{ids, resp.Total}
	}
	expect := func(query string, ids []string, total int) {
		t.Helper()
		got := get(query)
		if !slices.Equal(got.ids, ids) || got.total == nil || *got.total != total {
			t.Errorf("?%s: %v of %v, want %v of %d", query, got.ids, got.total, ids, total)
		}
	}

	const box = "bbox=-31,-31,-30,-30"
	expect(box, []string{newer, older}, 2)
	expect(box+"&from=2026-05-01&to=2026-05-01", []string{older}, 1)
	// Cut at the limit, the total still counts the whole area, by the tracks' boxes: the line that
	// goes round the view counts there, though it isn't listed.
	expect(box+"&limit=1", []string{newer}, 3)

	for _, bbox := range []string{"179,-41,181,-40", "179,-41,-179,-40", "-181,-41,-179,-40", "-180,-41,-179,-40"} {
		expect("bbox="+bbox, []string{dateline}, 1)
	}
	expect("bbox=170,-41,171,-40", nil, 0)

	// Without an area: the newest of the whole history, no total, the opening view's read.
	if got := get(""); len(got.ids) != 6 || got.total != nil {
		t.Errorf("no area: %d rows, total %v, want 6 and none", len(got.ids), got.total)
	}
	if got := get("limit=2"); len(got.ids) != 2 || got.ids[0] != dateline || got.total != nil {
		t.Errorf("limit=2: %v, total %v, want the two newest", got.ids, got.total)
	}

	for _, bad := range []string{"bbox=a,b,c,d", "bbox=-30,-31,-30,-30", "limit=0", "limit=1001", "limit=x"} {
		if rec := d.do(me, "GET", "/v2/tracks/area?"+bad, nil); rec.Code != http.StatusBadRequest {
			t.Errorf("?%s: status %d, want 400", bad, rec.Code)
		}
	}

	// A slim row: the Edit window's fields are GET /v2/tracks/{id}'s alone.
	rec := d.do(me, "GET", "/v2/tracks/area?"+box, nil)
	var raw struct {
		Tracks []map[string]json.RawMessage `json:"tracks"`
	}
	d.decode(rec, http.StatusOK, &raw)
	for _, field := range []string{"description", "edited", "track_edit", "photos", "split", "duration_seconds"} {
		if _, ok := raw.Tracks[0][field]; ok {
			t.Errorf("area row carries %q", field)
		}
	}
}

// A track with no route (FR-7.1) is listed while the circle of the location it is listed under
// reaches the view, with that circle's bbox, under the same Dates and cap (FR-5.11). Another
// location's circle, even one overlapping, never brings it in.
func TestListAreaHiddenTracks(t *testing.T) {
	d := newDBTest(t)
	me := d.newAccount(false)
	ctx := context.Background()
	const radiusM = 500
	type circle struct{ lon, lat float64 }
	zone := func(c circle) string {
		var id string
		if err := d.pool.QueryRow(ctx, `INSERT INTO privacy_zones (user_id, center, radius_m)
			VALUES ($1, ST_SetSRID(ST_MakePoint($2, $3), 4326)::geography, $4) RETURNING id`, me.id, c.lon, c.lat, radiusM).Scan(&id); err != nil {
			t.Fatal(err)
		}
		return id
	}
	hidden := func(day int, zoneID string) string {
		id := d.newTrack(me, testTrack{trackType: "walking", startedAt: time.Date(2026, 5, day, 10, 0, 0, 0, time.UTC)})
		if _, err := d.pool.Exec(ctx, `UPDATE tracks SET hidden_by = NULLIF($2, '')::uuid WHERE id = $1`, id, zoneID); err != nil {
			t.Fatal(err)
		}
		return id
	}
	// a and b overlap (857 m apart); c is on its own; d crosses the antimeridian.
	ca, cb, cc, cd := circle{10, 50}, circle{10.012, 50}, circle{12, 50}, circle{179.999, 0}
	inA, inB, inC, inD := hidden(1, zone(ca)), hidden(2, zone(cb)), hidden(3, zone(cc)), hidden(5, zone(cd))
	hidden(4, "") // its location deleted, its job not run yet: in no view
	boxes := map[string][]float64{}
	for id, c := range map[string]circle{inA: ca, inB: cb, inC: cc, inD: cd} {
		boxes[id] = circleBBox(c.lon, c.lat, radiusM)
	}
	boxA, boxB, boxC := boxes[inA], boxes[inB], boxes[inC]

	list := func(query string) ([]string, int) {
		t.Helper()
		var resp areaResponse
		d.decode(d.do(me, "GET", "/v2/tracks/area?"+query, nil), http.StatusOK, &resp)
		ids := []string{}
		for _, r := range resp.Tracks {
			ids = append(ids, r.ID)
			if !sameBBox(r.BBox, boxes[r.ID]) {
				t.Errorf("?%s: %s's bbox %v, want its circle's %v", query, r.ID, r.BBox, boxes[r.ID])
			}
		}
		total := -1
		if resp.Total != nil {
			total = *resp.Total
		}
		return ids, total
	}
	view := func(w, s, e, n float64) string { return fmt.Sprintf("bbox=%.6f,%.6f,%.6f,%.6f", w, s, e, n) }
	band := func(w, e float64) string { return view(w, 49.9, e, 50.1) }
	const eps = 0.0005 // about 36 m of longitude here
	for _, tc := range []struct {
		name  string
		query string
		want  []string
	}{
		{"a circle in view", band(11.99, 12.01), []string{inC}},
		{"a circle partly in view", band(boxC[2]-eps, boxC[2]+eps), []string{inC}},
		{"a circle out of view", band(boxC[2]+eps, boxC[2]+3*eps), []string{}},
		{"the circle's bbox in view, the circle not", view(boxC[2]-0.0015, boxC[3]-0.0005, 12.1, 50.1), []string{}},
		{"only the first of two overlapping circles", band(boxA[0]-eps, boxA[0]+eps), []string{inA}},
		{"only the second", band(boxB[2]-eps, boxB[2]+eps), []string{inB}},
		{"both", band(9.9, 10.1), []string{inB, inA}},
		{"under Dates", band(9.9, 10.1) + "&from=2026-05-02", []string{inB}},
		{"a view across the antimeridian", band(11.99, -179), []string{inC}},
		{"a circle across the antimeridian", view(-179.999, -0.01, -179.99, 0.01), []string{inD}},
	} {
		if got, total := list(tc.query); !slices.Equal(got, tc.want) || total != len(tc.want) {
			t.Errorf("%s: %v of %d, want %v", tc.name, got, total, tc.want)
		}
	}
	// Past the cap, the total counts them as the list does.
	if got, total := list(band(9.9, 10.1) + "&limit=1"); len(got) != 1 || total != 2 {
		t.Errorf("limit=1: %v of %d, want one of 2", got, total)
	}
	// The full row carries the same bbox, so a Trip's list flies there too.
	if row := d.track(me, inA); !sameBBox(row.BBox, boxA) {
		t.Errorf("GET /v2/tracks row bbox %v, want %v", row.BBox, boxA)
	}
}

// One track in full, for the Edit window; another account's is a 404, like a missing one.
func TestGetTrack(t *testing.T) {
	d := newDBTest(t)
	me := d.newAccount(false)
	other := d.newAccount(false)
	id := d.newTrack(me, testTrack{trackType: "hiking", at: &[2]float64{-30.5, -30.5}})
	var resp tracksResponse
	d.decode(d.do(me, "GET", "/v2/tracks/"+id, nil), http.StatusOK, &resp)
	if len(resp.Tracks) != 1 || resp.Tracks[0].ID != id || resp.Types["hiking"].Label == "" {
		t.Fatalf("got %+v", resp)
	}
	for _, as := range []account{other} {
		if rec := d.do(as, "GET", "/v2/tracks/"+id, nil); rec.Code != http.StatusNotFound {
			t.Errorf("another account: status %d, want 404", rec.Code)
		}
	}
	if rec := d.do(me, "GET", "/v2/tracks/not-a-uuid", nil); rec.Code != http.StatusNotFound {
		t.Errorf("malformed id: status %d, want 404", rec.Code)
	}
}

// A tracks tile's `since` keeps only tracks starting at or after it: the web's map past the
// list's cap (FR-5.11).
func TestTracksTileSince(t *testing.T) {
	d := newDBTest(t)
	me := d.newAccount(false)
	at := [2]float64{-30.5, -30.5}
	d.newTrack(me, testTrack{trackType: "hiking", startedAt: time.Date(2026, 5, 1, 10, 0, 0, 0, time.UTC), at: &at})
	d.newTrack(me, testTrack{trackType: "hiking", startedAt: time.Date(2026, 5, 3, 10, 0, 0, 0, time.UTC), at: &at})
	x, y := tilemathtest.LonLatToTile(at[0], at[1], 12)
	tile := func(query string) int {
		t.Helper()
		rec := d.do(me, "GET", fmt.Sprintf("/tiles/v1/tracks/12/%d/%d.mvt?%s", x, y, query), nil)
		d.decode(rec, http.StatusOK, nil)
		return rec.Body.Len()
	}
	both, newer := tile(""), tile("since=2026-05-03T10:00:00Z")
	if newer == 0 || newer >= both {
		t.Errorf("since the newer one's start: %d bytes, want some and fewer than both's %d", newer, both)
	}
	if n := tile("since=2026-05-03T10:00:01Z"); n != 0 {
		t.Errorf("since after both: %d bytes, want none", n)
	}
	if rec := d.do(me, "GET", fmt.Sprintf("/tiles/v1/tracks/12/%d/%d.mvt?since=yesterday", x, y), nil); rec.Code != http.StatusBadRequest {
		t.Errorf("a bad since: status %d, want 400", rec.Code)
	}
}

// The list doesn't filter by type or Trip, so asking it to is refused rather than answered
// with the whole set.
func TestListAreaRefusesFiltersItDoesNotApply(t *testing.T) {
	s := &Server{}
	for _, q := range []string{"types=walking", "trip=any"} {
		rec := httptest.NewRecorder()
		s.handleListArea(rec, httptest.NewRequest(http.MethodGet, "/v2/tracks/area?"+q, nil))
		if rec.Code != http.StatusBadRequest {
			t.Errorf("%s: %d, want 400", q, rec.Code)
		}
	}
}

// An empty types= or trip= is no filter, as on the other lists, so it is answered.
func TestListAreaTakesEmptyFilters(t *testing.T) {
	d := newDBTest(t)
	me := d.newAccount(false)
	if rec := d.do(me, http.MethodGet, "/v2/tracks/area?types=&trip=", nil); rec.Code != http.StatusOK {
		t.Fatalf("empty filters: %d, want 200", rec.Code)
	}
}
