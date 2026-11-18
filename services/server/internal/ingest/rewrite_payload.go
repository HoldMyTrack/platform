package ingest

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"

	"github.com/HoldMyTrack/platform/services/server/internal/storage"
	"github.com/jackc/pgx/v5/pgxpool"
)

// RewriteSyncPayloadJob is a `rewrite_sync_payload` job's payload: one stored phone-sync
// payload whose type is still named activity_type. Migration 0057 queues one per object;
// parse.JSONActivity reads the old name meanwhile, and both go once every payload is rewritten.
type RewriteSyncPayloadJob struct {
	Key string `json:"key"`
}

// RewriteSyncPayload renames the stored payload's activity_type to track_type and stores its
// new size where the tracks or the waiting ingest it backs keep it. A payload already renamed,
// or that nothing points at any more, is done. A track deleted while the payload is rewritten
// would leave the rewrite behind with nothing pointing at it, so the object goes again then.
func RewriteSyncPayload(ctx context.Context, pool *pgxpool.Pool, store *storage.Store, j RewriteSyncPayloadJob) error {
	referenced, err := syncPayloadReferenced(ctx, pool, j.Key)
	if err != nil {
		return err
	}
	if !referenced {
		return nil
	}
	r, err := store.Get(ctx, j.Key)
	if err != nil {
		return err
	}
	data, err := io.ReadAll(r)
	r.Close()
	if storage.IsNotFound(err) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("rewrite sync payload: read %s: %w", j.Key, err)
	}
	out, changed, err := renameSyncPayloadType(data)
	if err != nil {
		return fmt.Errorf("rewrite sync payload %s: %w", j.Key, err)
	}
	if !changed {
		return nil
	}
	if err := store.Put(ctx, j.Key, bytes.NewReader(out), int64(len(out))); err != nil {
		return err
	}
	if _, err := pool.Exec(ctx, `
		UPDATE tracks SET raw_bytes = $2 WHERE raw_payload_key = $1`, j.Key, len(out)); err != nil {
		return fmt.Errorf("rewrite sync payload: size of %s: %w", j.Key, err)
	}
	if _, err := pool.Exec(ctx, `
		UPDATE jobs SET payload = jsonb_set(payload, '{raw_bytes}', to_jsonb($2::bigint))
		WHERE kind = 'ingest' AND state = 'pending' AND payload ->> 'raw_payload_key' = $1 AND payload ? 'raw_bytes'`, j.Key, len(out)); err != nil {
		return fmt.Errorf("rewrite sync payload: size of %s: %w", j.Key, err)
	}
	if referenced, err = syncPayloadReferenced(ctx, pool, j.Key); err != nil || referenced {
		return err
	}
	return store.Remove(ctx, j.Key)
}

// syncPayloadReferenced reports whether a track, or an ingest still to run, points at key.
func syncPayloadReferenced(ctx context.Context, pool *pgxpool.Pool, key string) (bool, error) {
	var referenced bool
	err := pool.QueryRow(ctx, `
		SELECT EXISTS (SELECT 1 FROM tracks WHERE raw_payload_key = $1)
		    OR EXISTS (SELECT 1 FROM jobs WHERE kind = 'ingest' AND state = 'pending' AND payload ->> 'raw_payload_key' = $1)`, key).Scan(&referenced)
	if err != nil {
		return false, fmt.Errorf("rewrite sync payload: look up %s: %w", key, err)
	}
	return referenced, nil
}

// renameSyncPayloadType is data with its top-level activity_type renamed track_type, and
// whether anything changed.
func renameSyncPayloadType(data []byte) ([]byte, bool, error) {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return nil, false, err
	}
	old, ok := fields["activity_type"]
	if !ok {
		return data, false, nil
	}
	delete(fields, "activity_type")
	if _, ok := fields["track_type"]; !ok {
		fields["track_type"] = old
	}
	out, err := json.Marshal(fields)
	return out, true, err
}
