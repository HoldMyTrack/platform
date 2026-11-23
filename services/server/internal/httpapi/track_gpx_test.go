package httpapi

// Covers docs/SPEC.md FR-5.14 (GPX download).

import (
	"archive/zip"
	"bytes"
	"context"
	"io"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/HoldMyTrack/platform/services/server/internal/ingest"
)

func TestParseGPXIDs(t *testing.T) {
	a, b := "00000000-0000-4000-8000-00000000000A", "00000000-0000-4000-8000-00000000000b"
	ids, err := parseGPXIDs(query(t, "ids="+a+",+"+b+","+strings.ToLower(a)))
	if err != nil || len(ids) != 2 || ids[0] != strings.ToLower(a) || ids[1] != b {
		t.Fatalf("got %v %v, want each once, lowercased, in order", ids, err)
	}
	for _, bad := range []string{"", "ids=", "ids=42", "ids=" + a + ",", "ids=" + a + ",x"} {
		if _, err := parseGPXIDs(query(t, bad)); err == nil {
			t.Errorf("%q: parsed, want refused", bad)
		}
	}
}

func TestGPXRefusal(t *testing.T) {
	n := func(v int) *int { return &v }
	ok := gpxTrack{ID: "ok", Original: true, RawPoints: n(1000)}
	for _, tc := range []struct {
		name   string
		tracks []gpxTrack
		key    string
		names  string
	}{
		{"exportable", []gpxTrack{ok, ok}, "", ""},
		{"pending", []gpxTrack{ok, {ID: "p", Pending: true, Original: true}}, "error.gpx_pending", "p"},
		{"private", []gpxTrack{{ID: "h", Private: true, Original: true}, {ID: "p", Pending: true}}, "error.gpx_all_private", "h"},
		{"no original", []gpxTrack{ok, {ID: "n", RawPoints: n(2)}}, "error.gpx_no_original", "n"},
		{"at the cap", []gpxTrack{{Original: true, RawPoints: n(maxGPXPoints - 1000)}, ok}, "", ""},
		{"past the cap", []gpxTrack{{Original: true, RawPoints: n(maxGPXPoints)}, ok}, "error.gpx_too_large", ""},
		// An original not yet counted is counted as the download parses it.
		{"uncounted", []gpxTrack{{Original: true}, {Original: true, RawPoints: n(maxGPXPoints)}}, "", ""},
	} {
		key, track := gpxRefusal(tc.tracks)
		got := ""
		if track != nil {
			got = track.ID
		}
		if key != tc.key || got != tc.names {
			t.Errorf("%s: %q naming %q, want %q naming %q", tc.name, key, got, tc.key, tc.names)
		}
	}
}

func TestTracksGPX(t *testing.T) {
	s3 := newMemS3()
	d := newDBTestWithS3(t, s3)
	me, other := d.newAccount(false), d.newAccount(false)
	ctx := context.Background()
	day := func(n int) time.Time { return time.Date(2026, 5, n, 8, 0, 0, 0, time.UTC) }
	ride := d.recorded(s3, me, "Ride", day(1), 10)
	walk := d.recorded(s3, me, "Walk", day(2), 11)
	theirs := d.recorded(s3, other, "Theirs", day(1), 12)
	// Its start is now inside a Private location: the download leaves it out, as the map does.
	d.privateLocation(me, 10, 50, 150)

	var points int
	if err := d.pool.QueryRow(ctx, `SELECT raw_points FROM tracks WHERE id = $1`, ride).Scan(&points); err != nil || points != 61 {
		t.Fatalf("raw_points %d %v, want ingest to count the original's 61", points, err)
	}

	rec := d.do(me, "GET", "/v2/tracks/gpx?ids="+ride, nil)
	if rec.Code != http.StatusOK || rec.Header().Get("Content-Type") != "application/gpx+xml" {
		t.Fatalf("one track: %d %s %s", rec.Code, rec.Header().Get("Content-Type"), rec.Body.String())
	}
	if cd := rec.Header().Get("Content-Disposition"); !strings.HasPrefix(cd, "attachment") || !strings.Contains(cd, "2026-05-01 0800 Ride.gpx") {
		t.Errorf("Content-Disposition %q", cd)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "<trkpt") || strings.Contains(body, `lon="10"`) {
		t.Errorf("want the route without its start inside the Private location: %s", body[:min(len(body), 400)])
	}

	rec = d.do(me, "GET", "/v2/tracks/gpx?ids="+walk+","+ride, nil)
	if rec.Code != http.StatusOK || rec.Header().Get("Content-Type") != "application/zip" {
		t.Fatalf("two tracks: %d %s", rec.Code, rec.Body.String())
	}
	zr, err := zip.NewReader(bytes.NewReader(rec.Body.Bytes()), int64(rec.Body.Len()))
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, f := range zr.File {
		names = append(names, f.Name)
		r, _ := f.Open()
		b, _ := io.ReadAll(r)
		if !bytes.Contains(b, []byte("<trkpt")) {
			t.Errorf("%s holds no points", f.Name)
		}
	}
	if strings.Join(names, "|") != "2026-05-01 0800 Ride.gpx|2026-05-02 0800 Walk.gpx" {
		t.Errorf("zip holds %v, want both, oldest first", names)
	}

	refused := func(query string, status int, code, names string) {
		t.Helper()
		var e struct{ Error, Message string }
		d.decode(d.do(me, "GET", "/v2/tracks/gpx?"+query, nil), status, &e)
		if e.Error != code || !strings.Contains(e.Message, names) {
			t.Errorf("?%s: %s %q, want %s naming %q", query, e.Error, e.Message, code, names)
		}
	}
	refused("ids="+ride+","+theirs, http.StatusNotFound, "not_found", "")
	ids := make([]string, maxGPXTracks+1)
	for i := range ids {
		ids[i] = ride
	}
	if rec := d.do(me, "GET", "/v2/tracks/gpx?ids="+strings.Join(ids, ","), nil); rec.Code != http.StatusOK {
		t.Errorf("the same track 101 times is one: %d", rec.Code)
	}
	many := make([]string, maxGPXTracks+1)
	for i := range many {
		many[i] = d.newTrack(me, testTrack{trackType: "walking", startedAt: day(3)})
	}
	refused("ids="+strings.Join(many, ","), http.StatusBadRequest, "gpx_too_many", "100")

	noRoute := d.newTrack(me, testTrack{trackType: "walking", startedAt: day(4)})
	noOriginal := d.newTrack(me, testTrack{trackType: "hiking", startedAt: day(5), at: &[2]float64{20, 50}})
	refused("ids="+ride+","+noRoute, http.StatusConflict, "gpx_all_private", "walking (2026-05-04")
	refused("ids="+ride+","+noOriginal, http.StatusConflict, "gpx_no_original", "hiking (2026-05-05")

	if _, err := d.pool.Exec(ctx, `UPDATE tracks SET raw_points = $2 WHERE id = $1`, walk, maxGPXPoints); err != nil {
		t.Fatal(err)
	}
	refused("ids="+ride+","+walk, http.StatusRequestEntityTooLarge, "gpx_too_large", "")
	// An uncounted original is counted as it is parsed, past the cap too, and the count kept.
	if _, err := d.pool.Exec(ctx, `UPDATE tracks SET raw_points = CASE WHEN id = $1 THEN $2::int END WHERE id IN ($1, $3)`,
		walk, maxGPXPoints-60, ride); err != nil {
		t.Fatal(err)
	}
	refused("ids="+ride+","+walk, http.StatusRequestEntityTooLarge, "gpx_too_large", "")
	if err := d.pool.QueryRow(ctx, `SELECT raw_points FROM tracks WHERE id = $1`, ride).Scan(&points); err != nil || points != 61 {
		t.Errorf("raw_points %d %v, want the download to have stored 61", points, err)
	}
	if _, err := d.pool.Exec(ctx, `UPDATE tracks SET raw_points = 61, edit_pending = true WHERE id = $1`, walk); err != nil {
		t.Fatal(err)
	}
	refused("ids="+ride+","+walk, http.StatusConflict, "gpx_pending", "Walk (2026-05-02")
	if _, err := d.pool.Exec(ctx, `UPDATE tracks SET edit_pending = false WHERE id = $1`, walk); err != nil {
		t.Fatal(err)
	}

	broken := d.recorded(s3, me, "Broken", day(6), 13)
	var key string
	if err := d.pool.QueryRow(ctx, `SELECT raw_payload_key FROM tracks WHERE id = $1`, broken).Scan(&key); err != nil {
		t.Fatal(err)
	}
	s3.Put(key, []byte("not a gpx file"))
	refused("ids="+ride+","+broken, http.StatusConflict, "gpx_unreadable", "Broken (2026-05-06")

	demo := d.newAccount(true)
	demoTrack := d.recorded(s3, demo, "Demo", day(1), 14)
	if rec := d.do(demo, "GET", "/v2/tracks/gpx?ids="+demoTrack, nil); rec.Code != http.StatusOK {
		t.Errorf("demo: %d %s", rec.Code, rec.Body.String())
	}
}

// count_points counts the originals of tracks kept before raw_points, once for all the tracks
// sharing one, and leaves one that no longer reads uncounted.
func TestCountPoints(t *testing.T) {
	s3 := newMemS3()
	d := newDBTestWithS3(t, s3)
	me := d.newAccount(false)
	ctx := context.Background()
	at := time.Date(2026, 5, 1, 8, 0, 0, 0, time.UTC)
	good := d.recorded(s3, me, "Good", at, 10)
	broken := d.recorded(s3, me, "Broken", at.Add(24*time.Hour), 11)
	var key string
	if err := d.pool.QueryRow(ctx, `SELECT raw_payload_key FROM tracks WHERE id = $1`, broken).Scan(&key); err != nil {
		t.Fatal(err)
	}
	s3.Put(key, []byte("not a gpx file"))
	if _, err := d.pool.Exec(ctx, `UPDATE tracks SET raw_points = NULL WHERE user_id = $1`, me.id); err != nil {
		t.Fatal(err)
	}
	if err := ingest.CountPoints(ctx, d.pool, d.srv.store, ingest.CountPointsJob{UserID: me.id}); err != nil {
		t.Fatal(err)
	}
	for id, want := range map[string]*int{good: new(61), broken: nil} {
		var got *int
		if err := d.pool.QueryRow(ctx, `SELECT raw_points FROM tracks WHERE id = $1`, id).Scan(&got); err != nil {
			t.Fatal(err)
		}
		if (got == nil) != (want == nil) || (got != nil && *got != *want) {
			t.Errorf("%s: raw_points %v, want %v", id, got, want)
		}
	}
}

// Only a request that passes every check counts against the hourly limit.
func TestTracksGPXLimitCountsDownloadsOnly(t *testing.T) {
	s3 := newMemS3()
	d := newDBTestWithS3(t, s3)
	d.srv.gpxLimiter = newFixedWindowLimiter(1, time.Hour)
	me := d.newAccount(false)
	ride := d.recorded(s3, me, "Ride", time.Date(2026, 5, 1, 8, 0, 0, 0, time.UTC), 10)
	noOriginal := d.newTrack(me, testTrack{trackType: "hiking", at: &[2]float64{20, 50}})
	for range 3 {
		d.decode(d.do(me, "GET", "/v2/tracks/gpx?ids="+ride+","+noOriginal, nil), http.StatusConflict, nil)
	}
	if rec := d.do(me, "GET", "/v2/tracks/gpx?ids="+ride, nil); rec.Code != http.StatusOK {
		t.Fatalf("first download: %d %s", rec.Code, rec.Body.String())
	}
	d.decode(d.do(me, "GET", "/v2/tracks/gpx?ids="+ride, nil), http.StatusTooManyRequests, nil)
}

func TestRemoveStaleGPXFiles(t *testing.T) {
	t.Setenv("TMPDIR", t.TempDir())
	stale, err := os.CreateTemp("", gpxTempPattern)
	if err != nil {
		t.Fatal(err)
	}
	stale.Close()
	old := time.Now().Add(-2 * time.Hour)
	if err := os.Chtimes(stale.Name(), old, old); err != nil {
		t.Fatal(err)
	}
	fresh, err := os.CreateTemp("", gpxTempPattern)
	if err != nil {
		t.Fatal(err)
	}
	fresh.Close()
	removeStaleGPXFiles(slog.New(slog.DiscardHandler))
	if _, err := os.Stat(stale.Name()); !os.IsNotExist(err) {
		t.Errorf("stale file kept: %v", err)
	}
	if _, err := os.Stat(fresh.Name()); err != nil {
		t.Errorf("fresh file removed: %v", err)
	}
}
