package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"slices"
	"testing"
	"time"
)

// The area list (FR-5.19): the tracks crossing a view, newest first, capped with the area's
// total, across the antimeridian either way round, in slim rows.
func TestListArea(t *testing.T) {
	d := newDBTest(t)
	me := d.newAccount(false)
	ctx := context.Background()
	day := func(n int) time.Time { return time.Date(2026, 5, n, 10, 0, 0, 0, time.UTC) }
	track := func(started time.Time, wkt string) string {
		id := d.newActivity(me, testActivity{activityType: "hiking", startedAt: started, at: &[2]float64{0, 0}})
		if _, err := d.pool.Exec(ctx, `UPDATE activities SET trajectory = ST_GeomFromText($2, 4326) WHERE id = $1`, id, wkt); err != nil {
			t.Fatal(err)
		}
		return id
	}
	older := d.newActivity(me, testActivity{activityType: "hiking", startedAt: day(1), at: &[2]float64{-30.6, -30.6}})
	newer := d.newActivity(me, testActivity{activityType: "running", startedAt: day(2), at: &[2]float64{-30.4, -30.4}})
	d.newActivity(me, testActivity{activityType: "hiking", startedAt: day(3), at: &[2]float64{-20.5, -30.5}}) // outside
	d.newActivity(me, testActivity{activityType: "hiking", startedAt: day(4)})                                // no track (FR-8.1)
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
		d.decode(d.do(me, "GET", "/v1/activities/area?"+query, nil), http.StatusOK, &resp)
		var ids []string
		for _, a := range resp.Activities {
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
	// Cut at the limit, the total still counts the whole area.
	expect(box+"&limit=1", []string{newer}, 2)

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
		if rec := d.do(me, "GET", "/v1/activities/area?"+bad, nil); rec.Code != http.StatusBadRequest {
			t.Errorf("?%s: status %d, want 400", bad, rec.Code)
		}
	}

	// A slim row: the Edit window's fields are GET /v1/activities/{id}'s alone.
	rec := d.do(me, "GET", "/v1/activities/area?"+box, nil)
	var raw struct {
		Activities []map[string]json.RawMessage `json:"activities"`
	}
	d.decode(rec, http.StatusOK, &raw)
	for _, field := range []string{"description", "edited", "track_edit", "photos", "split", "duration_seconds"} {
		if _, ok := raw.Activities[0][field]; ok {
			t.Errorf("area row carries %q", field)
		}
	}
}

// One activity in full, for the Edit window; another account's is a 404, like a missing one.
func TestGetActivity(t *testing.T) {
	d := newDBTest(t)
	me := d.newAccount(false)
	other := d.newAccount(false)
	id := d.newActivity(me, testActivity{activityType: "hiking", at: &[2]float64{-30.5, -30.5}})
	var resp activitiesResponse
	d.decode(d.do(me, "GET", "/v1/activities/"+id, nil), http.StatusOK, &resp)
	if len(resp.Activities) != 1 || resp.Activities[0].ID != id || resp.Types["hiking"].Label == "" {
		t.Fatalf("got %+v", resp)
	}
	for _, as := range []account{other} {
		if rec := d.do(as, "GET", "/v1/activities/"+id, nil); rec.Code != http.StatusNotFound {
			t.Errorf("another account: status %d, want 404", rec.Code)
		}
	}
	if rec := d.do(me, "GET", "/v1/activities/not-a-uuid", nil); rec.Code != http.StatusNotFound {
		t.Errorf("malformed id: status %d, want 404", rec.Code)
	}
}
