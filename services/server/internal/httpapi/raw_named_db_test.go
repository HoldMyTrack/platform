package httpapi

import (
	"context"
	"testing"

	"github.com/HoldMyTrack/platform/services/server/internal/ingest"
)

// An original is named by its owner's activity or pending ingest, unless that ingest is the
// one asking.
func TestRawNamed(t *testing.T) {
	d := newDBTest(t)
	ctx := context.Background()
	rider := d.newAccount(false)
	kept, queued := "raw/"+rider.id+"/kept.gpx", "raw/"+rider.id+"/queued.gpx"
	activity := d.newActivity(rider, testActivity{activityType: "walk"})
	if _, err := d.pool.Exec(ctx, `UPDATE activities SET raw_payload_key = $1 WHERE id = $2`, kept, activity); err != nil {
		t.Fatal(err)
	}
	var job int64
	if err := d.pool.QueryRow(ctx, `
		INSERT INTO jobs (kind, user_id, payload) VALUES ('ingest', $1, jsonb_build_object('raw_payload_key', $2::text))
		RETURNING id`, rider.id, queued).Scan(&job); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { d.pool.Exec(context.Background(), `DELETE FROM jobs WHERE id = $1`, job) })

	for _, tc := range []struct {
		key    string
		except int64
		want   bool
	}{
		{kept, 0, true},
		{queued, 0, true},
		{queued, job, false},
		{"raw/" + rider.id + "/gone.gpx", 0, false},
	} {
		got, err := ingest.RawNamed(ctx, d.pool, rider.id, tc.key, tc.except)
		if err != nil || got != tc.want {
			t.Errorf("RawNamed(%s, except %d) = %v, %v; want %v", tc.key, tc.except, got, err, tc.want)
		}
	}
	if got, _ := ingest.RawNamed(ctx, d.pool, d.newAccount(false).id, kept, 0); got {
		t.Error("another account's lookup found the rider's original")
	}
}
