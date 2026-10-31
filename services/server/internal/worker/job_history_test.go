package worker

import (
	"context"
	"log/slog"
	"testing"
)

// Finished jobs go 90 days after they finish; a recent one and a pending one, however old, stay.
func TestSweepJobHistoryRemovesOldFinishedJobs(t *testing.T) {
	pool, userID := testPool(t)
	ctx := context.Background()
	job := func(state, finishedAgo, createdAgo string) int64 {
		t.Helper()
		var id int64
		if err := pool.QueryRow(ctx, `
			INSERT INTO jobs (kind, user_id, payload, state, finished_at, created_at)
			VALUES ('test_unknown', $1, '{}', $2, NOW() - $3::interval, NOW() - $4::interval) RETURNING id`,
			userID, state, finishedAgo, createdAgo).Scan(&id); err != nil {
			t.Fatalf("insert job: %v", err)
		}
		return id
	}
	oldDone := job("done", "91 days", "91 days")
	oldFailed := job("failed", "100 days", "100 days")
	recent := job("done", "89 days", "200 days")
	pending := job("pending", "0", "200 days")
	if _, err := pool.Exec(ctx, `UPDATE jobs SET finished_at = NULL WHERE id = $1`, pending); err != nil {
		t.Fatal(err)
	}

	if err := sweepJobHistory(ctx, pool, slog.New(slog.DiscardHandler)); err != nil {
		t.Fatal(err)
	}
	for id, want := range map[int64]bool{oldDone: false, oldFailed: false, recent: true, pending: true} {
		var exists bool
		if err := pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM jobs WHERE id = $1)`, id).Scan(&exists); err != nil {
			t.Fatal(err)
		}
		if exists != want {
			t.Errorf("job %d kept = %v, want %v", id, exists, want)
		}
	}
}
