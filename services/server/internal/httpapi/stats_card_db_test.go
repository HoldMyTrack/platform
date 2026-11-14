package httpapi

import (
	"bytes"
	"context"
	"image/png"
	"net/http"
	"testing"
	"time"

	"github.com/HoldMyTrack/platform/services/server/internal/statscard"
)

// The stats card (SPEC FR-4.7) reads the asked activities newest first, leaves Pending ones out,
// marks one with no track Private, and refuses an id that isn't the account's.
func TestStatsCard(t *testing.T) {
	d := newDBTest(t)
	me, other := d.newAccount(false), d.newAccount(false)
	at := &[2]float64{13.4, 52.5}
	day := func(n int) time.Time { return time.Date(2026, 5, n, 10, 0, 0, 0, time.UTC) }
	moving := 1500
	older := d.newActivity(me, testActivity{activityType: "walking", distanceMeters: 2000, durationSecs: 1800, startedAt: day(1), at: at})
	newer := d.newActivity(me, testActivity{activityType: "cycling", distanceMeters: 20000, movingSeconds: &moving, durationSecs: 3600, startedAt: day(3), at: at})
	private := d.newActivity(me, testActivity{activityType: "hiking", startedAt: day(2)})
	pending := d.newActivity(me, testActivity{activityType: "running", distanceMeters: 5000, startedAt: day(4), at: at})
	theirs := d.newActivity(other, testActivity{activityType: "walking", at: at})
	ctx := context.Background()
	if _, err := d.pool.Exec(ctx, `UPDATE activities SET elevation_gain_m = 120 WHERE id = $1`, newer); err != nil {
		t.Fatal(err)
	}
	if _, err := d.pool.Exec(ctx, `UPDATE activities SET edit_pending = true WHERE id = $1`, pending); err != nil {
		t.Fatal(err)
	}

	acts, country, err := d.srv.statsCardActivities(ctx, me.id, []string{older, newer, private, pending})
	if err != nil {
		t.Fatal(err)
	}
	if country != "DE" {
		t.Errorf("country %q", country)
	}
	if len(acts) != 3 || acts[0].Type != "cycling" || acts[1].Type != "hiking" || acts[2].Type != "walking" {
		t.Fatalf("rows %+v, want cycling, hiking, walking", acts)
	}
	if *acts[0].MovingSeconds != 1500 || *acts[0].ElevationGainM != 120 || acts[0].Private {
		t.Errorf("cycling %+v", acts[0])
	}
	if !acts[1].Private || *acts[2].MovingSeconds != 1800 || acts[2].ElevationGainM != nil {
		t.Errorf("hiking %+v, walking %+v: want Private, and elapsed time for no moving time", acts[1], acts[2])
	}

	body := func(ids ...string) map[string]any {
		return map[string]any{"activity_ids": ids, "width": 1920, "height": 1080, "theme": "dark"}
	}
	rec := d.do(me, http.MethodPost, "/v1/activities/stats-card", body(older, newer, private))
	if rec.Code != http.StatusOK || rec.Header().Get("Content-Type") != "image/png" {
		t.Fatalf("status %d, type %q: %s", rec.Code, rec.Header().Get("Content-Type"), rec.Body)
	}
	img, err := png.Decode(bytes.NewReader(rec.Body.Bytes()))
	if err != nil {
		t.Fatal(err)
	}
	if want := statscard.FontPx(1920, 1080); float64(img.Bounds().Dy()) < 4*want {
		t.Errorf("card %v is shorter than its four lines", img.Bounds().Size())
	}

	if rec := d.do(me, http.MethodPost, "/v1/activities/stats-card", body(pending)); rec.Code != http.StatusNoContent {
		t.Errorf("only Pending: status %d, want 204", rec.Code)
	}
	if rec := d.do(me, http.MethodPost, "/v1/activities/stats-card", body(older, theirs)); rec.Code != http.StatusNotFound {
		t.Errorf("another account's: status %d, want 404", rec.Code)
	}
	for name, b := range map[string]map[string]any{
		"no ids":      body(),
		"bad id":      body("not-an-id"),
		"zero width":  {"activity_ids": []string{older}, "width": 0, "height": 1080, "theme": "dark"},
		"too tall":    {"activity_ids": []string{older}, "width": 1080, "height": 5000, "theme": "dark"},
		"other theme": {"activity_ids": []string{older}, "width": 1080, "height": 1080, "theme": "sepia"},
	} {
		if rec := d.do(me, http.MethodPost, "/v1/activities/stats-card", b); rec.Code != http.StatusBadRequest {
			t.Errorf("%s: status %d, want 400", name, rec.Code)
		}
	}

	d.srv.statsCardLimiter = newFixedWindowLimiter(1, time.Hour)
	d.do(me, http.MethodPost, "/v1/activities/stats-card", body(older))
	if rec := d.do(me, http.MethodPost, "/v1/activities/stats-card", body(older)); rec.Code != http.StatusTooManyRequests {
		t.Errorf("past the limit: status %d, want 429", rec.Code)
	}
}