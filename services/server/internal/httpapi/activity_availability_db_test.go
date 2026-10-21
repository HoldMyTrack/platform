package httpapi

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"testing"
	"time"

	"github.com/HoldMyTrack/platform/services/server/internal/ingest"
)

// The list says why Edit track or photos can't be used for a row (docs/SPEC.md FR-5.14), from
// what's stored, and stays silent when they can.
func TestActivityListAvailability(t *testing.T) {
	d := newDBTest(t)
	me := d.newAccount(false)
	at := [2]float64{-81.6, 41.5}
	set := func(id, sql string) {
		t.Helper()
		if _, err := d.pool.Exec(context.Background(), `UPDATE activities SET `+sql+` WHERE id = $1`, id); err != nil {
			t.Fatalf("update %s: %v", id, err)
		}
	}
	ok := d.newActivity(me, testActivity{activityType: "walking", at: &at})
	set(ok, `raw_payload_key = 'raw/x', editable_times = true`)
	unknown := d.newActivity(me, testActivity{activityType: "walking", at: &at})
	set(unknown, `raw_payload_key = 'raw/y'`)
	noOriginal := d.newActivity(me, testActivity{activityType: "walking", at: &at})
	badTimes := d.newActivity(me, testActivity{activityType: "walking", at: &at})
	set(badTimes, `raw_payload_key = 'raw/z', editable_times = false`)
	private := d.newActivity(me, testActivity{activityType: "walking"})
	set(private, `raw_payload_key = 'raw/w', editable_times = false`)

	for _, tc := range []struct {
		id, trackEdit, photos string
	}{
		{ok, "", ""},
		{unknown, "", ""},
		{noOriginal, blockedNoOriginal, ""},
		{badTimes, blockedBadTimes, ""},
		{private, blockedPrivate, blockedPrivate},
	} {
		got := d.activity(me, tc.id)
		if got.TrackEdit != tc.trackEdit || got.Photos != tc.photos {
			t.Errorf("%s: track_edit %q, photos %q; want %q, %q", tc.id, got.TrackEdit, got.Photos, tc.trackEdit, tc.photos)
		}
	}
}

// Ingest stores whether the track's timestamps run forward, and the backfill reads it back from
// the upload for a row stored before.
func TestEditableTimesStored(t *testing.T) {
	d := newDBTestWithS3(t, newMemS3())
	ctx := context.Background()
	me := d.newAccount(false)
	t0 := time.Date(2026, 4, 2, 9, 0, 0, 0, time.UTC)
	ingestWalk := func(key string, minutes []int) string {
		t.Helper()
		var points []map[string]any
		for i, m := range minutes {
			points = append(points, map[string]any{"lat": 50.0 + 0.003*float64(i), "lon": 10.0, "time": t0.Add(time.Duration(m) * time.Minute)})
		}
		body := map[string]any{"source": "recorded", "activities": []map[string]any{{"external_id": key, "activity_type": "walking", "points": points}}}
		var synced syncActivitiesResponse
		d.decode(d.do(me, http.MethodPost, "/v1/sync/activities", body), http.StatusOK, &synced)
		res, err := ingest.Process(ctx, d.pool, d.srv.store, d.latestIngestJob(me))
		if err != nil {
			t.Fatal(err)
		}
		return res.ActivityID
	}
	stored := func(id string) *bool {
		t.Helper()
		var v *bool
		if err := d.pool.QueryRow(ctx, `SELECT editable_times FROM activities WHERE id = $1`, id).Scan(&v); err != nil {
			t.Fatal(err)
		}
		return v
	}

	forward := ingestWalk("forward", []int{0, 1, 2, 3})
	backward := ingestWalk("backward", []int{0, 2, 1, 3})
	if v := stored(forward); v == nil || !*v {
		t.Fatalf("forward: editable_times %v, want true", v)
	}
	if v := stored(backward); v == nil || *v {
		t.Fatalf("backward: editable_times %v, want false", v)
	}
	if got := d.activity(me, backward).TrackEdit; got != blockedBadTimes {
		t.Fatalf("backward: track_edit %q, want %q", got, blockedBadTimes)
	}

	if _, err := d.pool.Exec(ctx, `UPDATE activities SET editable_times = NULL WHERE id = ANY($1)`, []string{forward, backward}); err != nil {
		t.Fatal(err)
	}
	if err := ingest.BackfillEditableTimes(ctx, d.pool, d.srv.store, slog.New(slog.NewTextHandler(io.Discard, nil))); err != nil {
		t.Fatal(err)
	}
	if v := stored(forward); v == nil || !*v {
		t.Fatalf("forward after the backfill: editable_times %v, want true", v)
	}
	if v := stored(backward); v == nil || *v {
		t.Fatalf("backward after the backfill: editable_times %v, want false", v)
	}
}
