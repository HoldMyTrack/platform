package worker

import (
	"bytes"
	"context"
	"io"
	"log/slog"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/HoldMyTrack/platform/services/server/internal/storage"
	"github.com/HoldMyTrack/platform/services/server/internal/storage/storagetest"
)

// A stored sync payload is rewritten to track_type with its track's size; one nothing points
// at any more is left alone, and its job still finishes.
func TestRewriteSyncPayloadJob(t *testing.T) {
	pool, userID := testPool(t)
	ctx := context.Background()
	srv := httptest.NewServer(storagetest.New())
	t.Cleanup(srv.Close)
	store, err := storage.New(srv.URL, "test", "test", "test")
	if err != nil {
		t.Fatal(err)
	}
	log := slog.New(slog.DiscardHandler)
	put := func(key, body string) {
		t.Helper()
		if err := store.Put(ctx, key, strings.NewReader(body), int64(len(body))); err != nil {
			t.Fatal(err)
		}
	}
	read := func(key string) string {
		t.Helper()
		r, err := store.Get(ctx, key)
		if err != nil {
			t.Fatal(err)
		}
		defer r.Close()
		b, err := io.ReadAll(r)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	old := `{"activity_type":"walking","points":[]}`
	kept, orphan := "raw/"+userID+"/recorded/r1.json", "raw/"+userID+"/recorded/gone.json"
	put(kept, old)
	put(orphan, old)
	if _, err := pool.Exec(ctx, `
		INSERT INTO tracks (user_id, source, track_type, started_at, timezone, raw_payload_key, raw_bytes)
		VALUES ($1, 'recorded', 'walking', now(), 'UTC', $2, $3)`, userID, kept, len(old)); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{kept, orphan} {
		if _, err := pool.Exec(ctx, `INSERT INTO jobs (kind, payload, run_after) VALUES ('rewrite_sync_payload', jsonb_build_object('key', $1::text), '2000-01-01')`, key); err != nil {
			t.Fatal(err)
		}
		if _, err := claimAndRunOne(ctx, pool, store, log); err != nil {
			t.Fatalf("run %s: %v", key, err)
		}
	}

	got := read(kept)
	if !strings.Contains(got, `"track_type":"walking"`) || strings.Contains(got, "activity_type") {
		t.Errorf("rewritten payload: %s", got)
	}
	var size int
	if err := pool.QueryRow(ctx, `SELECT raw_bytes FROM tracks WHERE raw_payload_key = $1`, kept).Scan(&size); err != nil || size != len(got) {
		t.Errorf("raw_bytes %d, %v; want %d", size, err, len(got))
	}
	if got := read(orphan); !bytes.Equal([]byte(got), []byte(old)) {
		t.Errorf("unreferenced payload changed: %s", got)
	}
	var unfinished int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM jobs WHERE kind = 'rewrite_sync_payload' AND state <> 'done'`).Scan(&unfinished); err != nil || unfinished != 0 {
		t.Errorf("%d rewrite jobs not done (%v)", unfinished, err)
	}
}
