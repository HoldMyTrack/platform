package ingest

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/HoldMyTrack/platform/services/server/internal/fog"
	"github.com/HoldMyTrack/platform/services/server/internal/storage"
)

// ReprivacyJob is the `reprivacy` job's payload (IMPLEMENTATION.md §7): the activities one
// Private location change may have affected, to be reprocessed against the account's
// current set of locations.
type ReprivacyJob struct {
	UserID      string   `json:"user_id"`
	ActivityIDs []string `json:"activity_ids"`
	// Retry is how many runs before this one failed on these activities (reprivacyRetryDelays).
	Retry int `json:"retry,omitempty"`
}

// reprivacyRetryDelays are the waits before each rerun of the activities a `reprivacy` run
// failed on. They stay Pending, and so off the map, until a run succeeds: their stored
// geometry was clipped without the new location. Once these run out they stay Pending.
var reprivacyRetryDelays = []time.Duration{time.Minute, 5 * time.Minute, 30 * time.Minute, 2 * time.Hour, 12 * time.Hour}

// zoneMarginM widens the affected-set search past where a clipped end can lie: the stored
// trajectory is simplified (a few metres of tolerance).
const zoneMarginM = 25

// AffectedActivities returns the activities of userID whose display trajectory comes within
// twice a circle's radius (plus zoneMarginM) of its center: every activity a location placed,
// or previously placed, there could clip. Twice, because ClipEnds cuts an end up to a radius
// further on past the edge (clipStart). Run inside the caller's transaction, alongside the
// privacy_zones change itself.
func AffectedActivities(ctx context.Context, tx pgx.Tx, userID string, lat, lon float64, radiusM int) ([]string, error) {
	rows, err := tx.Query(ctx, `
		SELECT id FROM activities
		WHERE user_id = $1 AND raw_payload_key IS NOT NULL
		  AND trajectory IS NOT NULL
		  AND ST_DWithin(trajectory::geography, ST_SetSRID(ST_MakePoint($3, $2), 4326)::geography, $4)
	`, userID, lat, lon, 2*radiusM+zoneMarginM)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[string])
}

// AffectedHiddenActivities is AffectedActivities for the activities a location change can
// bring back but that have no trajectory to search by — those entirely inside Private
// locations. There are few, and reprocessing one that stays hidden changes nothing. Hidden
// duplicates are included for the same reason as there.
func AffectedHiddenActivities(ctx context.Context, tx pgx.Tx, userID string) ([]string, error) {
	rows, err := tx.Query(ctx, `
		SELECT id FROM activities
		WHERE user_id = $1 AND raw_payload_key IS NOT NULL
		  AND trajectory IS NULL
	`, userID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[string])
}

// EnqueueReprivacy marks every given activity Pending — the same flag, and the same Activity
// List badge, as a track edit (§4.7.7) — and enqueues one `reprivacy` job for all of them,
// inside the caller's transaction so a location is never saved without its reprocessing on
// the way. Unlike EnqueueTrackEdit it doesn't skip an activity already pending: an edit in
// flight was clipped with the old locations, and this job, queued behind it, fixes that.
// Their tiles are marked dirty too, so the job's first render drops them from Fog/Heatmap
// (markPendingTilesDirty).
func EnqueueReprivacy(ctx context.Context, tx pgx.Tx, job ReprivacyJob) error {
	if len(job.ActivityIDs) == 0 {
		return nil
	}
	if _, err := tx.Exec(ctx, `
		UPDATE activities SET edit_pending = true WHERE user_id = $1 AND id = ANY($2::uuid[])
	`, job.UserID, job.ActivityIDs); err != nil {
		return err
	}
	if err := markPendingTilesDirty(ctx, tx, job.UserID, job.ActivityIDs); err != nil {
		return err
	}
	// Pending drops them from the tracks tiles now, not at the job's first render.
	if err := fog.BumpMapVersion(ctx, tx, job.UserID); err != nil {
		return err
	}
	payload, err := json.Marshal(job)
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `INSERT INTO jobs (kind, user_id, payload) VALUES ('reprivacy', $1, $2)`, job.UserID, payload)
	return err
}

// ProcessReprivacy reprocesses a batch of activities against the account's current Private
// locations. It renders twice, each time every dirty tile once — not one composite per
// activity, which for a location at home would redo the same busy tiles hundreds of times:
// first before reprocessing, which drops the batch (Pending, and so left out of the render)
// from Fog/Heatmap; then after clearing Pending, which brings it back with its new masks.
// Pending therefore clears just before the second render; the client refreshes Fog/Heatmap
// off the coverage status (this job counts as rendering until it returns), not off the badge.
//
// An activity that fails stays Pending: clearing the flag would put its old geometry, clipped
// without the new location, back on the map. A later job reruns it (reprivacyRetryDelays),
// queued in the transaction that clears the rest, and this job still fails, naming them.
func ProcessReprivacy(ctx context.Context, pool *pgxpool.Pool, store *storage.Store, jobID int64, job ReprivacyJob) error {
	if err := fog.RenderUser(ctx, pool, store, job.UserID); err != nil {
		return retryReprivacy(ctx, pool, job, job.ActivityIDs, fmt.Errorf("reprivacy: render fog/heatmap: %w", err))
	}

	var done, failedIDs, failed []string
	for _, id := range job.ActivityIDs {
		if err := reprocessActivity(ctx, pool, store, job.UserID, id, nil); err != nil {
			failedIDs = append(failedIDs, id)
			failed = append(failed, fmt.Sprintf("%s: %v", id, err))
			continue
		}
		done = append(done, id)
	}

	tx, err := pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("reprivacy: begin: %w", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck // no-op once committed
	if len(failedIDs) > 0 {
		if err := enqueueReprivacyRetry(ctx, tx, job, failedIDs); err != nil {
			return fmt.Errorf("reprivacy: queue retry: %w", err)
		}
	}
	// A later location change still queued for any of these will reprocess it again — leave
	// its badge on until that one lands.
	if _, err := tx.Exec(ctx, `
		UPDATE activities a SET edit_pending = false
		WHERE a.user_id = $1 AND a.id = ANY($2::uuid[])
		  AND NOT EXISTS (
			SELECT 1 FROM jobs j
			WHERE j.user_id = $1 AND j.kind = 'reprivacy' AND j.state = 'pending' AND j.id > $3
			  AND j.payload->'activity_ids' ? a.id::text
		  )
	`, job.UserID, done, jobID); err != nil {
		return fmt.Errorf("reprivacy: clear edit_pending: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("reprivacy: commit: %w", err)
	}
	if err := fog.RenderUser(ctx, pool, store, job.UserID); err != nil {
		return fmt.Errorf("reprivacy: render fog/heatmap: %w", err)
	}

	if len(failed) > 0 {
		return fmt.Errorf("reprivacy: %d of %d activities failed: %s", len(failed), len(job.ActivityIDs), strings.Join(failed, "; "))
	}
	return nil
}

// retryReprivacy queues a rerun of ids after a failure that left them all Pending, and returns
// cause for the job's own failure.
func retryReprivacy(ctx context.Context, pool *pgxpool.Pool, job ReprivacyJob, ids []string, cause error) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return errors.Join(cause, fmt.Errorf("reprivacy: queue retry: %w", err))
	}
	defer tx.Rollback(ctx) //nolint:errcheck // no-op once committed
	if err := enqueueReprivacyRetry(ctx, tx, job, ids); err != nil {
		return errors.Join(cause, fmt.Errorf("reprivacy: queue retry: %w", err))
	}
	if err := tx.Commit(ctx); err != nil {
		return errors.Join(cause, fmt.Errorf("reprivacy: queue retry: %w", err))
	}
	return cause
}

// enqueueReprivacyRetry queues the next rerun of ids after job failed on them, or none once
// reprivacyRetryDelays has run out, which leaves them Pending.
func enqueueReprivacyRetry(ctx context.Context, tx pgx.Tx, job ReprivacyJob, ids []string) error {
	delay, ok := reprivacyRetryDelay(job.Retry)
	if !ok {
		return nil
	}
	payload, err := json.Marshal(ReprivacyJob{UserID: job.UserID, ActivityIDs: ids, Retry: job.Retry + 1})
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `
		INSERT INTO jobs (kind, user_id, payload, run_after)
		VALUES ('reprivacy', $1, $2, NOW() + make_interval(secs => $3))
	`, job.UserID, payload, delay.Seconds())
	return err
}

// reprivacyRetryDelay is the wait before the rerun that follows a failure of retry-th rerun
// (0 for the first run), and false once there are no reruns left.
func reprivacyRetryDelay(retry int) (time.Duration, bool) {
	if retry < 0 || retry >= len(reprivacyRetryDelays) {
		return 0, false
	}
	return reprivacyRetryDelays[retry], true
}

// markPendingTilesDirty flags every z14 tile the given activities' current masks cover, inside
// the transaction that marks them Pending — so the reprocess job's first render leaves them out
// of Fog/Heatmap, and the tiles are already dirty however soon that job runs. The same upsert
// as MarkFogTilesDirty, fed straight from activity_tile_masks rather than a tile list.
func markPendingTilesDirty(ctx context.Context, tx pgx.Tx, userID string, activityIDs []string) error {
	_, err := tx.Exec(ctx, `
		INSERT INTO fog_tiles (user_id, zoom, tile_x, tile_y, dirty)
		SELECT DISTINCT $1::uuid, m.zoom, m.tile_x, m.tile_y, true
		FROM activity_tile_masks m
		WHERE m.activity_id = ANY($2::uuid[]) AND m.zoom = $3
		ON CONFLICT (user_id, zoom, tile_x, tile_y) DO UPDATE SET dirty = true, dirty_gen = fog_tiles.dirty_gen + 1
	`, userID, activityIDs, FogZoom)
	return err
}
