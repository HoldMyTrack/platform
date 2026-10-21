package ingest

import (
	"context"
	"fmt"
	"log/slog"
	"sync/atomic"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/HoldMyTrack/platform/services/server/internal/parallel"
	"github.com/HoldMyTrack/platform/services/server/internal/storage"
)

// BackfillEditableTimes fills editable_times (migration 0044) for every activity stored before
// ingest set it, from its raw payload: the piece's points clipped against the account's Private
// locations, as the Track tab gets them. One-off, run once on deploying migration 0044
// (`backfill-editable-times`); idempotent, since it only reads rows still missing it, and a
// reprocess that sets it meanwhile wins. An activity whose payload can't be read is logged and
// left NULL, which the list treats as editable and the points request still refuses.
func BackfillEditableTimes(ctx context.Context, pool *pgxpool.Pool, store *storage.Store, log *slog.Logger) error {
	type row struct {
		id, userID, sourceDetail, rawKey string
		rng                              SplitRange
	}
	rows, err := pool.Query(ctx, `
		SELECT id::text, user_id::text, COALESCE(source_detail, ''), raw_payload_key, split_from, split_to
		FROM activities
		WHERE editable_times IS NULL AND raw_payload_key IS NOT NULL
		ORDER BY user_id, started_at
	`)
	if err != nil {
		return fmt.Errorf("list activities: %w", err)
	}
	var todo []row
	for rows.Next() {
		var r row
		if err := rows.Scan(&r.id, &r.userID, &r.sourceDetail, &r.rawKey, &r.rng.From, &r.rng.To); err != nil {
			rows.Close()
			return err
		}
		todo = append(todo, r)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}

	var filled, skipped atomic.Int64
	err = parallel.ForEach(ctx, len(todo), rerenderParallelism, func(ctx context.Context, i int) error {
		r := todo[i]
		points, _, err := LoadPiecePoints(ctx, pool, store, r.userID, r.sourceDetail, r.rawKey, r.rng)
		if err != nil {
			log.Warn("backfill-editable-times: skipped", "activity", r.id, "err", err)
			skipped.Add(1)
			return nil
		}
		if _, err := pool.Exec(ctx, `
			UPDATE activities SET editable_times = $2
			WHERE id = $1 AND editable_times IS NULL
		`, r.id, EditableTimestamps(points) == nil); err != nil {
			return fmt.Errorf("update %s: %w", r.id, err)
		}
		filled.Add(1)
		return nil
	})
	if err != nil {
		return err
	}
	log.Info("backfill-editable-times: done", "filled", filled.Load(), "skipped", skipped.Load())
	return nil
}
