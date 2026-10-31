package worker

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// jobHistoryRetention is how long a finished job is kept: the import history the Upload menu,
// /sync and the apps' Sync history show (docs/SPEC.md FR-3.4), and every other kind's record. A
// pending job is never removed.
const jobHistoryRetention = 90 * 24 * time.Hour

// jobHistoryInterval is how often sweepJobHistory runs; a day's lateness is nothing against 90.
const jobHistoryInterval = 24 * time.Hour

// jobHistoryBatch bounds one DELETE, so the first sweep over a long-grown table doesn't hold
// one long lock.
const jobHistoryBatch = 5000

// sweepJobHistory deletes done and failed jobs that finished more than jobHistoryRetention ago.
// A row from before finished_at existed counts from when it was created.
func sweepJobHistory(ctx context.Context, pool *pgxpool.Pool, log *slog.Logger) error {
	total := int64(0)
	for {
		tag, err := pool.Exec(ctx, `
			DELETE FROM jobs WHERE id IN (
				SELECT id FROM jobs
				WHERE state IN ('done', 'failed')
				  AND COALESCE(finished_at, created_at) < NOW() - make_interval(secs => $1)
				LIMIT $2
			)`, jobHistoryRetention.Seconds(), jobHistoryBatch)
		if err != nil {
			return fmt.Errorf("job history sweep: %w", err)
		}
		total += tag.RowsAffected()
		if tag.RowsAffected() < jobHistoryBatch {
			break
		}
	}
	if total > 0 {
		log.Info("job history swept", "jobs", total)
	}
	return nil
}
