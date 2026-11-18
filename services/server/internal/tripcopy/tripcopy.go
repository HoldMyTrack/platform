// Package tripcopy copies a Trip into another account — the `trip_copy` job behind sending
// a copy of a Trip (IMPLEMENTATION.md §4.23, ADR-0036). Its own package because it writes
// each track out with export.WriteGPX and reads it back in through ingest.Process, and
// export already imports ingest.
package tripcopy

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/HoldMyTrack/platform/services/server/internal/export"
	"github.com/HoldMyTrack/platform/services/server/internal/fog"
	"github.com/HoldMyTrack/platform/services/server/internal/ingest"
	"github.com/HoldMyTrack/platform/services/server/internal/storage"
)

// Job is the `trip_copy` job's payload: copy the Trip, as it is when the job runs, into the
// recipient's account. Accepting a sent copy enqueues it (httpapi's handleAcceptTripSend).
type Job struct {
	TripID      string `json:"trip_id"`
	RecipientID string `json:"recipient_id"`
}

// Source is tracks.source for a track a copy made.
const Source = "trip"

// retryAfter is how long a copy waits before trying again the tracks it skipped because
// their owner had an edit still being applied.
const retryAfter = time.Minute

// Querier is what Enqueue runs on: the pool, or the transaction taking the copy out of the
// recipient's inbox.
type Querier = ingest.Querier

// Enqueue adds a `trip_copy` job for the recipient, to run after delay.
func Enqueue(ctx context.Context, db Querier, job Job, delay time.Duration) error {
	payload, err := json.Marshal(job)
	if err != nil {
		return err
	}
	_, err = db.Exec(ctx, `
		INSERT INTO jobs (kind, user_id, payload, run_after)
		VALUES ('trip_copy', $1, $2, NOW() + make_interval(secs => $3))`,
		job.RecipientID, payload, delay.Seconds())
	return err
}

// source is one track of the Trip being copied, and the original it stands for.
type source struct {
	id, origin, trackType string
	name, description     *string
	pending               bool
}

// Process copies the Trip into the recipient's account (ADR-0036):
//
//   - into the Trip an earlier copy of the same Trip made for them (trip_copies), or a new
//     one with the Trip's name and description when there's none, or it was deleted;
//   - each track the recipient hasn't received before — an original is received once,
//     ever (received_origins), and one they recorded themselves, or hold a copy of, is skipped;
//   - from the points the sender sees (ingest.DisplayedPoints: their Private locations and track
//     edit applied), written as GPX and run through the ordinary ingest as the recipient's
//     track, so the recipient's own Private locations apply on top;
//   - with its name, type and description, and its photos as the recipient's rows over the same
//     image files.
//
// A track with no visible track is left out. One whose owner has an edit still being
// applied is skipped for now, and the job enqueues itself again for it; a copy with nothing
// else to add makes no Trip until then. Every step is safe to
// repeat: the ingest is idempotent on (recipient, 'trip', origin), and the rest are inserts
// that ignore what's already there, so a copy cut off partway finishes on the next run.
//
// A Trip deleted meanwhile, or one whose owner is being deleted, copies nothing.
func Process(ctx context.Context, pool *pgxpool.Pool, store *storage.Store, job Job) error {
	var name string
	var description *string
	err := pool.QueryRow(ctx, `
		SELECT st.name, st.description FROM trips st JOIN users u ON u.id = st.user_id
		WHERE st.id = $1 AND u.deleted_at IS NULL`, job.TripID).Scan(&name, &description)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("trip copy: trip: %w", err)
	}

	sources, err := sourcesToCopy(ctx, pool, job)
	if err != nil {
		return err
	}
	ready, retry := plan(sources)
	if ready == 0 && retry {
		// Everything left to copy waits on an edit: no Trip until there's something in it.
		return Enqueue(ctx, pool, job, retryAfter)
	}
	target, err := targetTrip(ctx, pool, job, name, description, ready > 0)
	if err != nil || target == "" {
		return err
	}

	added := false
	for _, src := range sources {
		if src.pending {
			continue
		}
		copied, err := copyTrack(ctx, pool, store, job.RecipientID, target, src)
		if err != nil {
			return fmt.Errorf("trip copy: track %s: %w", src.id, err)
		}
		added = added || copied
	}
	if added {
		if _, err := pool.Exec(ctx, `UPDATE trips SET updated_at = NOW() WHERE id = $1`, target); err != nil {
			return fmt.Errorf("trip copy: touch trip: %w", err)
		}
		// The new memberships change what a `?trip=` tracks tile returns (§4.23).
		if err := fog.BumpMapVersion(ctx, pool, job.RecipientID); err != nil {
			return fmt.Errorf("trip copy: bump map version: %w", err)
		}
	}
	if retry {
		return Enqueue(ctx, pool, job, retryAfter)
	}
	return nil
}

// plan is how many of sources this run copies, and whether the job has to run again for the
// rest: a track whose owner has an edit still being applied waits for it.
func plan(sources []source) (ready int, retry bool) {
	for _, src := range sources {
		if !src.pending {
			ready++
		}
	}
	return ready, ready < len(sources)
}

// sourcesToCopy lists the Trip's tracks with a track, and a raw payload to rebuild it
// from, that the recipient has neither received, recorded nor holds a copy of, oldest first.
func sourcesToCopy(ctx context.Context, pool *pgxpool.Pool, job Job) ([]source, error) {
	rows, err := pool.Query(ctx, `
		SELECT a.id, COALESCE(a.origin_id, a.id), a.track_type, a.name, a.description, a.edit_pending
		FROM trip_tracks sa
		JOIN tracks a ON a.id = sa.track_id
		WHERE sa.trip_id = $1 AND a.trajectory IS NOT NULL AND a.raw_payload_key IS NOT NULL
		  AND NOT EXISTS (SELECT 1 FROM received_origins r WHERE r.user_id = $2 AND r.origin_id = COALESCE(a.origin_id, a.id))
		  AND NOT EXISTS (SELECT 1 FROM tracks mine
		                  WHERE mine.user_id = $2 AND (mine.id = COALESCE(a.origin_id, a.id) OR mine.origin_id = COALESCE(a.origin_id, a.id)))
		ORDER BY a.started_at, a.id`, job.TripID, job.RecipientID)
	if err != nil {
		return nil, fmt.Errorf("trip copy: tracks: %w", err)
	}
	sources, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (source, error) {
		var s source
		err := row.Scan(&s.id, &s.origin, &s.trackType, &s.name, &s.description, &s.pending)
		return s, err
	})
	if err != nil {
		return nil, fmt.Errorf("trip copy: tracks: %w", err)
	}
	return sources, nil
}

// targetTrip is the recipient's Trip an earlier copy of this one made, or a new one with its
// name and description. With nothing to copy, a missing Trip is made only when the Trip being
// copied is itself empty — accepting an empty Trip gives an empty Trip — and otherwise the
// answer is "", since the recipient already has everything in it.
func targetTrip(ctx context.Context, pool *pgxpool.Pool, job Job, name string, description *string, anything bool) (string, error) {
	var target string
	err := pool.QueryRow(ctx, `SELECT copy_trip_id FROM trip_copies WHERE source_trip_id = $1 AND recipient_id = $2`,
		job.TripID, job.RecipientID).Scan(&target)
	if err == nil {
		return target, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return "", fmt.Errorf("trip copy: earlier copy: %w", err)
	}
	if !anything {
		var empty bool
		if err := pool.QueryRow(ctx, `SELECT NOT EXISTS (SELECT 1 FROM trip_tracks WHERE trip_id = $1)`, job.TripID).Scan(&empty); err != nil {
			return "", fmt.Errorf("trip copy: empty: %w", err)
		}
		if !empty {
			return "", nil
		}
	}
	err = pool.QueryRow(ctx, `
		WITH st AS (INSERT INTO trips (user_id, name, description) VALUES ($2, $3, $4) RETURNING id)
		INSERT INTO trip_copies (source_trip_id, recipient_id, copy_trip_id)
		SELECT $1, $2, id FROM st
		RETURNING copy_trip_id`, job.TripID, job.RecipientID, name, description).Scan(&target)
	if err != nil {
		return "", fmt.Errorf("trip copy: new trip: %w", err)
	}
	return target, nil
}

// sourceDetail is the file name a copy is listed under: its name, or its type when it has none.
func sourceDetail(src source) string {
	label := src.trackType
	if src.name != nil && *src.name != "" {
		label = *src.name
	}
	return export.Slug(label) + ".gpx"
}

// copyTrack makes the recipient's copy of src in target, reporting whether it added one. An
// track whose track the sender's Private locations hide entirely adds nothing.
func copyTrack(ctx context.Context, pool *pgxpool.Pool, store *storage.Store, recipientID, target string, src source) (bool, error) {
	points, err := ingest.DisplayedPoints(ctx, pool, store, src.id)
	if err != nil {
		return false, err
	}
	if points == nil {
		return false, nil
	}
	var gpx bytes.Buffer
	if err := export.WriteGPX(&gpx, src.trackType, points); err != nil {
		return false, err
	}
	rawKey := fmt.Sprintf("raw/%s/%s/%s.gpx", recipientID, Source, src.origin)
	if err := store.Put(ctx, rawKey, bytes.NewReader(gpx.Bytes()), int64(gpx.Len())); err != nil {
		return false, err
	}
	res, err := ingest.Process(ctx, pool, store, ingest.Job{
		UserID:        recipientID,
		Source:        Source,
		SourceDetail:  sourceDetail(src),
		ExternalID:    src.origin,
		RawPayloadKey: rawKey,
		RawBytes:      int64(gpx.Len()),
		TrackType:     src.trackType,
	})
	if err != nil {
		return false, err
	}

	tx, err := pool.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck // no-op once committed
	if _, err := tx.Exec(ctx, `UPDATE tracks SET origin_id = $2, name = $3, description = $4 WHERE id = $1`,
		res.TrackID, src.origin, src.name, src.description); err != nil {
		return false, err
	}
	// FOR KEY SHARE holds the sender's photo rows until commit, so a photo deleted meanwhile
	// waits, and then finds this copy's row naming its files and leaves them
	// (ingest.RemoveUnreferencedPhotoFiles).
	if _, err := tx.Exec(ctx, `
		WITH src AS (SELECT * FROM track_photos WHERE track_id = $1 FOR KEY SHARE)
		INSERT INTO track_photos (user_id, track_id, taken_at, route_at, content_type, thumb_content_type, width, height, bytes, caption, image_key)
		SELECT $2, $3, taken_at, route_at, content_type, thumb_content_type, width, height, bytes, caption, image_key FROM src
		WHERE NOT EXISTS (SELECT 1 FROM track_photos p WHERE p.track_id = $3 AND p.image_key = src.image_key)`,
		src.id, recipientID, res.TrackID); err != nil {
		return false, err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO trip_tracks (trip_id, track_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`,
		target, res.TrackID); err != nil {
		return false, err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO received_origins (user_id, origin_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`,
		recipientID, src.origin); err != nil {
		return false, err
	}
	return true, tx.Commit(ctx)
}
