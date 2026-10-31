package worker

import (
	"context"
	"log/slog"
	"net/http/httptest"
	"testing"

	"github.com/HoldMyTrack/platform/services/server/internal/ingest"
	"github.com/HoldMyTrack/platform/services/server/internal/storage"
	"github.com/HoldMyTrack/platform/services/server/internal/storage/storagetest"
)

// A failed ingest leaves no original behind (docs/DPIA.md: originals are kept as long as their
// activity): neither the job row's inline copy nor the object at its raw key, unless an activity
// still names that key.
func TestFailedIngestDiscardsItsOriginal(t *testing.T) {
	pool, userID := testPool(t)
	ctx := context.Background()
	s3 := storagetest.New()
	srv := httptest.NewServer(s3)
	t.Cleanup(srv.Close)
	store, err := storage.New(srv.URL, "test", "test", "test")
	if err != nil {
		t.Fatalf("store: %v", err)
	}
	log := slog.New(slog.DiscardHandler)

	// failing enqueues a file that can't be parsed, runs its job, and returns its raw key.
	failing := func(data string) (int64, string) {
		t.Helper()
		if _, err := ingest.EnqueueRaw(ctx, pool, userID, []ingest.RawItem{{Source: "upload", Filename: "broken.gpx", Ext: ".gpx", Data: []byte(data)}}); err != nil {
			t.Fatalf("enqueue: %v", err)
		}
		var id int64
		var key string
		if err := pool.QueryRow(ctx, `
			UPDATE jobs SET run_after = '2000-01-01' WHERE id = (SELECT max(id) FROM jobs WHERE user_id = $1 AND kind = 'ingest')
			RETURNING id, payload->>'raw_payload_key'`, userID).Scan(&id, &key); err != nil {
			t.Fatalf("job: %v", err)
		}
		if _, err := claimAndRunOne(ctx, pool, store, log); err != nil {
			t.Fatalf("run: %v", err)
		}
		if r := readJob(t, pool, id); r.state != "failed" {
			t.Fatalf("job %d: %+v, want failed", id, r)
		}
		var inline bool
		if err := pool.QueryRow(ctx, `SELECT raw IS NOT NULL FROM jobs WHERE id = $1`, id).Scan(&inline); err != nil || inline {
			t.Errorf("job %d still holds its bytes inline (%v)", id, err)
		}
		return id, key
	}

	_, key := failing("not a track")
	if s3.Has(key) {
		t.Errorf("failed ingest's original %s is still stored", key)
	}

	// The same bytes again while an activity names the key: the object stays.
	if _, err := pool.Exec(ctx, `
		INSERT INTO activities (user_id, source, external_id, activity_type, started_at, timezone, raw_payload_key)
		VALUES ($1, 'upload', 'other', 'run', NOW(), 'UTC', $2)`, userID, key); err != nil {
		t.Fatalf("activity: %v", err)
	}
	if _, kept := failing("not a track"); !s3.Has(kept) {
		t.Errorf("original %s removed while an activity still names it", kept)
	}
}
