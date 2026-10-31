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
// again after retryDelays; once they're spent it fails for good.
func TestJobFailingOnAnOutageIsRetriedThenFails(t *testing.T) {
	pool, userID := testPool(t)
	ctx := context.Background()
	srv := httptest.NewServer(storagetest.New())
	t.Cleanup(srv.Close)
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
	var attempts int
	var locked bool
	var secs float64
	if err := pool.QueryRow(ctx, `
		SELECT state, attempts, locked_at IS NOT NULL, EXTRACT(EPOCH FROM run_after - NOW())::float8
		FROM jobs WHERE id = $1`, id).Scan(&state, &attempts, &locked, &secs); err != nil {
		t.Fatal(err)
	}
	wait := time.Duration(secs * float64(time.Second))
	if state != "pending" || attempts != 1 || locked || wait < 50*time.Second || wait > retryDelays[0] {
		t.Fatalf("after the first failure: %s, attempt %d, locked %v, runs in %v; want pending, unlocked, in about %v", state, attempts, locked, wait, retryDelays[0])
	}

	// Its last retry: spent, so it fails.
	if _, err := pool.Exec(ctx, `UPDATE jobs SET attempts = $2, run_after = '2000-01-01' WHERE id = $1`, id, len(retryDelays)); err != nil {
		t.Fatal(err)
	}
	if _, err := claimAndRunOne(ctx, pool, store, log); err != nil {
		t.Fatal(err)
	}
	if r := readJob(t, pool, id); r.state != "failed" || r.attempts != maxAttempts {
		t.Errorf("after the last retry: %+v, want failed on attempt %d", r, maxAttempts)
	}
}
