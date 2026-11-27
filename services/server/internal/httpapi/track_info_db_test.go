package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/HoldMyTrack/platform/services/server/internal/trackinfo"
)

// Info (SPEC FR-5.8) has one track's lines or a group's totals in the account's units, and
// refuses an id that isn't the account's.
func TestTrackInfo(t *testing.T) {
	d := newDBTest(t)
	me, other := d.newAccount(false), d.newAccount(false)
	at := &[2]float64{13.4, 52.5}
	moving := 1500
	ride := d.newTrack(me, testTrack{trackType: "cycling", distanceMeters: 20000, movingSeconds: &moving, durationSecs: 3600, startedAt: time.Date(2026, 5, 3, 10, 0, 0, 0, time.UTC), at: at, timezone: "UTC"})
	walk := d.newTrack(me, testTrack{trackType: "walking", distanceMeters: 2000, durationSecs: 1800, startedAt: time.Date(2026, 5, 1, 10, 0, 0, 0, time.UTC), at: at, timezone: "UTC"})
	theirs := d.newTrack(other, testTrack{trackType: "walking", at: at})
	if _, err := d.pool.Exec(context.Background(), `UPDATE tracks SET elevation_gain_m = 120 WHERE id = $1`, ride); err != nil {
		t.Fatal(err)
	}

	info := func(ids ...string) trackinfo.Info {
		t.Helper()
		rec := d.do(me, http.MethodPost, "/v2/tracks/info", map[string]any{"track_ids": ids})
		if rec.Code != http.StatusOK {
			t.Fatalf("status %d: %s", rec.Code, rec.Body)
		}
		var got trackinfo.Info
		if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
			t.Fatal(err)
		}
		return got
	}
	values := func(i trackinfo.Info) map[string]string {
		out := map[string]string{}
		for _, l := range i.Lines {
			out[l.Label] = l.Value
		}
		return out
	}

	one := values(info(ride))
	if one["Start"] != "May 3, 2026, 10:00 AM" || one["Moving time"] != "25m" || one["Elevation gain"] != "120 m" || one["Speed"] != "48.0 km/h" {
		t.Errorf("one track %v", one)
	}
	group := values(info(ride, walk))
	if group["Tracks"] != "2" || group["Distance"] != "22 km" || group["First start"] != "May 1, 2026, 10:00 AM" {
		t.Errorf("group %v", group)
	}

	if rec := d.do(me, http.MethodPost, "/v2/tracks/info", map[string]any{"track_ids": []string{ride, theirs}}); rec.Code != http.StatusNotFound {
		t.Errorf("another account's: status %d, want 404", rec.Code)
	}
	for name, b := range map[string]map[string]any{"no ids": {"track_ids": []string{}}, "bad id": {"track_ids": []string{"x"}}} {
		if rec := d.do(me, http.MethodPost, "/v2/tracks/info", b); rec.Code != http.StatusBadRequest {
			t.Errorf("%s: status %d, want 400", name, rec.Code)
		}
	}

	d.srv.trackInfoLimiter = newFixedWindowLimiter(1, time.Hour)
	d.do(me, http.MethodPost, "/v2/tracks/info", map[string]any{"track_ids": []string{ride}})
	if rec := d.do(me, http.MethodPost, "/v2/tracks/info", map[string]any{"track_ids": []string{ride}}); rec.Code != http.StatusTooManyRequests {
		t.Errorf("past the limit: status %d, want 429", rec.Code)
	}
}
