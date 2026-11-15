package httpapi

// Covers docs/SPEC.md FR-5.7 and docs/IMPLEMENTATION.md §4.7.7: a track edit the tile limit
// refuses leaves the activity as it was.

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/HoldMyTrack/platform/services/server/internal/ingest"
)

func TestTrackEditPastTheTileLimitChangesNothing(t *testing.T) {
	d := newDBTestWithS3(t, newMemS3())
	ctx := context.Background()
	me := d.newAccount(false)
	const gpx = `<?xml version="1.0"?><gpx version="1.1" creator="test"><trk><trkseg>
<trkpt lat="50.0000" lon="10.0000"><time>2026-05-01T10:00:00Z</time></trkpt>
<trkpt lat="50.0010" lon="10.0000"><time>2026-05-11T10:00:00Z</time></trkpt>
<trkpt lat="50.0020" lon="10.0000"><time>2026-05-21T10:00:00Z</time></trkpt>
</trkseg></trk></gpx>`
	if resp := d.uploadFile(me, "short.gpx", []byte(gpx)); resp.Status != "enqueued" {
		t.Fatalf("upload: %q", resp.Status)
	}
	res, err := ingest.Process(ctx, d.pool, d.srv.store, d.latestIngestJob(me))
	if err != nil || !res.Persisted {
		t.Fatalf("ingest: %+v, %v", res, err)
	}
	type row struct {
		distance float64
		edited   bool
		pending  bool
	}
	read := func() row {
		var r row
		if err := d.pool.QueryRow(ctx, `
			SELECT distance_meters, track_edit IS NOT NULL, edit_pending FROM activities WHERE id = $1
		`, res.ActivityID).Scan(&r.distance, &r.edited, &r.pending); err != nil {
			t.Fatal(err)
		}
		return r
	}
	before := read()

	// The middle point dragged to near the far side of the Earth: its two segments cross far
	// more map tiles than one activity may touch. The points are days apart, so the track's
	// speed still fits its column and only the tile limit refuses it.
	middle := time.Date(2026, 5, 11, 10, 0, 0, 0, time.UTC).UnixMilli()
	edit := map[string]any{"move": map[int64][2]float64{middle: {-170, -50}}}
	d.decode(d.do(me, http.MethodPost, "/v1/activities/"+res.ActivityID+"/track-edit", map[string]any{"edit": edit}), http.StatusAccepted, nil)

	var payload []byte
	if err := d.pool.QueryRow(ctx, `SELECT payload FROM jobs WHERE user_id = $1 AND kind = 'edit_track' ORDER BY id DESC LIMIT 1`, me.id).Scan(&payload); err != nil {
		t.Fatal(err)
	}
	var job ingest.EditJob
	if err := json.Unmarshal(payload, &job); err != nil {
		t.Fatal(err)
	}
	if err := ingest.ProcessTrackEdit(ctx, d.pool, d.srv.store, job); err == nil || !strings.Contains(err.Error(), "map tiles") {
		t.Fatalf("an edit past the tile limit: %v, want refused for its tiles", err)
	}
	if after := read(); after != before {
		t.Fatalf("the refused edit changed the activity: %+v, was %+v", after, before)
	}
}

// A split whose second piece the tile limit refuses leaves both pieces as they were when the
// split was saved: every piece is checked before any is written.
func TestSplitEditPastTheTileLimitChangesNoPiece(t *testing.T) {
	d := newDBTestWithS3(t, newMemS3())
	ctx := context.Background()
	me := d.newAccount(false)
	const gpx = `<?xml version="1.0"?><gpx version="1.1" creator="test"><trk><trkseg>
<trkpt lat="50.0000" lon="10.0000"><time>2026-05-01T10:00:00Z</time></trkpt>
<trkpt lat="50.0010" lon="10.0000"><time>2026-05-11T10:00:00Z</time></trkpt>
<trkpt lat="50.0020" lon="10.0000"><time>2026-05-21T10:00:00Z</time></trkpt>
<trkpt lat="50.0030" lon="10.0000"><time>2026-05-31T10:00:00Z</time></trkpt>
<trkpt lat="50.0040" lon="10.0000"><time>2026-06-10T10:00:00Z</time></trkpt>
</trkseg></trk></gpx>`
	if resp := d.uploadFile(me, "long.gpx", []byte(gpx)); resp.Status != "enqueued" {
		t.Fatalf("upload: %q", resp.Status)
	}
	res, err := ingest.Process(ctx, d.pool, d.srv.store, d.latestIngestJob(me))
	if err != nil || !res.Persisted {
		t.Fatalf("ingest: %+v, %v", res, err)
	}
	day := func(d int) int64 { return time.Date(2026, 5, d, 10, 0, 0, 0, time.UTC).UnixMilli() }
	// The second piece is days 21, 31 and 41 (June 10); its middle point moved to the far side
	// of the Earth gives it two segments past the tile limit, while the first piece is fine.
	edit := map[string]any{"move": map[int64][2]float64{day(31): {-170, -50}}}
	d.decode(d.do(me, http.MethodPost, "/v1/activities/"+res.ActivityID+"/track-edit", map[string]any{"edit": edit, "split_at": day(16)}), http.StatusAccepted, nil)

	pieces := func() string {
		var out string
		if err := d.pool.QueryRow(ctx, `
			SELECT string_agg(concat_ws(' ', distance_meters, track_edit IS NOT NULL), '; ' ORDER BY started_at)
			FROM activities WHERE user_id = $1
		`, me.id).Scan(&out); err != nil {
			t.Fatal(err)
		}
		return out
	}
	before := pieces()

	var payload []byte
	if err := d.pool.QueryRow(ctx, `SELECT payload FROM jobs WHERE user_id = $1 AND kind = 'edit_track' ORDER BY id DESC LIMIT 1`, me.id).Scan(&payload); err != nil {
		t.Fatal(err)
	}
	var job ingest.EditJob
	if err := json.Unmarshal(payload, &job); err != nil {
		t.Fatal(err)
	}
	if err := ingest.ProcessTrackEdit(ctx, d.pool, d.srv.store, job); err == nil || !strings.Contains(err.Error(), "map tiles") {
		t.Fatalf("a split edit past the tile limit: %v, want refused for its tiles", err)
	}
	if after := pieces(); after != before {
		t.Fatalf("the refused split edit changed the pieces: %s, was %s", after, before)
	}
}
