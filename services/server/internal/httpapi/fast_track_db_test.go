package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/HoldMyTrack/platform/services/server/internal/ingest"
)

// A track whose points imply more than 1 km/s, a GPS jump or a clock glitch, ingests, and an
// edit that makes it faster still is saved: no stored column bounds an activity's speed.
func TestFastTrackIngestsAndEdits(t *testing.T) {
	d := newDBTestWithS3(t, newMemS3())
	ctx := context.Background()
	me := d.newAccount(false)
	// About 11 km in two seconds.
	const gpx = `<?xml version="1.0"?><gpx version="1.1" creator="test"><trk><trkseg>
<trkpt lat="50.0000" lon="10.0000"><time>2026-05-01T10:00:00Z</time></trkpt>
<trkpt lat="50.0500" lon="10.0000"><time>2026-05-01T10:00:01Z</time></trkpt>
<trkpt lat="50.1000" lon="10.0000"><time>2026-05-01T10:00:02Z</time></trkpt>
</trkseg></trk></gpx>`
	if resp := d.uploadFile(me, "fast.gpx", []byte(gpx)); resp.Status != "enqueued" {
		t.Fatalf("upload: %q", resp.Status)
	}
	res, err := ingest.Process(ctx, d.pool, d.srv.store, d.latestIngestJob(me))
	if err != nil || !res.Persisted {
		t.Fatalf("ingest: %+v, %v", res, err)
	}

	// The middle point moved 50 km further out: two 50 km segments a second each.
	middle := time.Date(2026, 5, 1, 10, 0, 1, 0, time.UTC).UnixMilli()
	edit := map[string]any{"move": map[int64][2]float64{middle: {10, 50.5}}}
	d.decode(d.do(me, http.MethodPost, "/v1/activities/"+res.ActivityID+"/track-edit", map[string]any{"edit": edit}), http.StatusAccepted, nil)
	var payload []byte
	if err := d.pool.QueryRow(ctx, `SELECT payload FROM jobs WHERE user_id = $1 AND kind = 'edit_track' ORDER BY id DESC LIMIT 1`, me.id).Scan(&payload); err != nil {
		t.Fatal(err)
	}
	var job ingest.EditJob
	if err := json.Unmarshal(payload, &job); err != nil {
		t.Fatal(err)
	}
	if err := ingest.ProcessTrackEdit(ctx, d.pool, d.srv.store, job); err != nil {
		t.Fatalf("edit implying 50 km/s: %v", err)
	}
	var meters float64
	if err := d.pool.QueryRow(ctx, `SELECT distance_meters FROM activities WHERE id = $1`, res.ActivityID).Scan(&meters); err != nil {
		t.Fatal(err)
	}
	if meters < 90_000 {
		t.Errorf("distance after the edit = %.0f m, want the moved point's ~100 km", meters)
	}
}
