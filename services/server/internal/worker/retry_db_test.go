package worker

import (
	"context"
	"fmt"
	"log/slog"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/HoldMyTrack/platform/services/server/internal/storage"
	"github.com/HoldMyTrack/platform/services/server/internal/storage/storagetest"
)

// An ingest that fails on something passing (its original can't be read) stays pending and runs
// again after retryDelays, then every longest delay without end: an accepted file is never
// failed for our fault.
func TestIngestFailingOnAnOutageIsRetriedWithoutEnd(t *testing.T) {
	pool, userID := testPool(t)
	ctx := context.Background()
	// A store that doesn't answer.
	srv := httptest.NewServer(storagetest.New())
	srv.Close()
	store, err := storage.New(srv.URL, "test", "test", "test")
	if err != nil {
		t.Fatalf("store: %v", err)
	}
	log := slog.New(slog.DiscardHandler)
	payload := fmt.Sprintf(`{"user_id":%q,"source":"upload","source_detail":"x.gpx","external_id":"retry-test","raw_payload_key":"raw/%s/missing.gpx"}`, userID, userID)
	id := insertJobOfKind(t, pool, userID, "ingest", payload, "2000-01-01T00:00:00Z", 0, nil)

	if _, err := claimAndRunOne(ctx, pool, store, log); err != nil {
		t.Fatal(err)
	}
	var state string
	var attempts, retries int
	var locked bool
	var secs float64
	read := func() time.Duration {
		t.Helper()
		if err := pool.QueryRow(ctx, `
			SELECT state, attempts, retries, locked_at IS NOT NULL, EXTRACT(EPOCH FROM run_after - NOW())::float8
			FROM jobs WHERE id = $1`, id).Scan(&state, &attempts, &retries, &locked, &secs); err != nil {
			t.Fatal(err)
		}
		return time.Duration(secs * float64(time.Second))
	}
	if wait := read(); state != "pending" || attempts != 1 || retries != 1 || locked || wait < 50*time.Second || wait > retryDelays[0] {
		t.Fatalf("after the first failure: %s, attempt %d, retry %d, locked %v, runs in %v; want pending, unlocked, in about %v", state, attempts, retries, locked, wait, retryDelays[0])
	}

	// Past every delay, and more runs than maxCrashes: still retried, since none crashed.
	n := len(retryDelays) + maxCrashes
	if _, err := pool.Exec(ctx, `UPDATE jobs SET attempts = $2, retries = $2, run_after = '2000-01-01' WHERE id = $1`, id, n); err != nil {
		t.Fatal(err)
	}
	if _, err := claimAndRunOne(ctx, pool, store, log); err != nil {
		t.Fatal(err)
	}
	last := retryDelays[len(retryDelays)-1]
	if wait := read(); state != "pending" || retries != n+1 || wait < last-time.Minute || wait > last {
		t.Errorf("after %d retries: %s, retry %d, runs in %v; want pending, in about %v", n, state, retries, wait, last)
	}
}

// An ingest whose original is missing from storage fails at once: no rerun brings it back.
func TestIngestWithItsOriginalMissingFails(t *testing.T) {
	pool, userID := testPool(t)
	ctx := context.Background()
	srv := httptest.NewServer(storagetest.New())
	t.Cleanup(srv.Close)
	store, err := storage.New(srv.URL, "test", "test", "test")
	if err != nil {
		t.Fatalf("store: %v", err)
	}
	payload := fmt.Sprintf(`{"user_id":%q,"source":"upload","source_detail":"x.gpx","external_id":"missing-test","raw_payload_key":"raw/%s/missing.gpx"}`, userID, userID)
	id := insertJobOfKind(t, pool, userID, "ingest", payload, "2000-01-01T00:00:00Z", 0, nil)
	if _, err := claimAndRunOne(ctx, pool, store, slog.New(slog.DiscardHandler)); err != nil {
		t.Fatal(err)
	}
	if r := readJob(t, pool, id); r.state != "failed" {
		t.Errorf("job %+v, want failed", r)
	}
}
