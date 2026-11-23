package ingest

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/HoldMyTrack/platform/services/server/internal/storage"
)

// CountPointsJob is the `count_points` job's payload: an account whose tracks kept before
// tracks.raw_points existed are to be counted (migration 0064).
type CountPointsJob struct {
	UserID string `json:"user_id"`
}

// CountPoints sets raw_points on every track of the account that lacks it, parsing each
// original once for all the tracks sharing it (the pieces of a split). An original that can't
// be read, for its own fault or the store's, stays uncounted and the rest are counted: a GPX
// download counts it when it parses it. A database failure fails the job, and a rerun picks up
// where it stopped.
func CountPoints(ctx context.Context, pool *pgxpool.Pool, store *storage.Store, job CountPointsJob) error {
	rows, err := pool.Query(ctx, `
		SELECT DISTINCT raw_payload_key, COALESCE(source_detail, '')
		FROM tracks
		WHERE user_id = $1 AND raw_points IS NULL AND raw_payload_key IS NOT NULL
	`, job.UserID)
	if err != nil {
		return fmt.Errorf("count points: list: %w", err)
	}
	type original struct{ key, sourceDetail string }
	var originals []original
	for rows.Next() {
		var o original
		if err := rows.Scan(&o.key, &o.sourceDetail); err != nil {
			rows.Close()
			return fmt.Errorf("count points: list: %w", err)
		}
		originals = append(originals, o)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return fmt.Errorf("count points: list: %w", err)
	}
	for _, o := range originals {
		act, err := loadRecorded(ctx, store, o.sourceDetail, o.key, 0)
		if err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			continue
		}
		if _, err := pool.Exec(ctx, `UPDATE tracks SET raw_points = $3 WHERE user_id = $1 AND raw_payload_key = $2`,
			job.UserID, o.key, len(act.Points)); err != nil {
			return fmt.Errorf("count points: %s: %w", o.key, err)
		}
	}
	return nil
}
