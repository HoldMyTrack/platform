package ingest

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"

	"github.com/HoldMyTrack/platform/services/server/internal/storage"
)

// RewriteSyncPayloadJob is a `rewrite_sync_payload` job's payload: one stored phone-sync
// payload whose type is still named activity_type. Migration 0057 queues one per object, ahead
// of anything the release queues, since parse.JSONActivity reads only track_type.
type RewriteSyncPayloadJob struct {
	Key string `json:"key"`
}

// RewriteSyncPayload renames the stored payload's activity_type to track_type. A payload that
// names neither, or names track_type already, is left as it is, so a rerun changes nothing.
func RewriteSyncPayload(ctx context.Context, store *storage.Store, j RewriteSyncPayloadJob) error {
	r, err := store.Get(ctx, j.Key)
	if err != nil {
		return err
	}
	data, err := io.ReadAll(r)
	r.Close()
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
	return store.Put(ctx, j.Key, bytes.NewReader(out), int64(len(out)))
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
