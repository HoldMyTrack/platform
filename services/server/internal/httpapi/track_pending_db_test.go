package httpapi

import (
	"context"
	"net/http"
	"testing"
)

// The Pending check (§4.2.5) answers which of the asked ids are still Pending, the account's only.
func TestTracksPending(t *testing.T) {
	d := newDBTest(t)
	me := d.newAccount(false)
	other := d.newAccount(false)
	pending := d.newTrack(me, testTrack{trackType: "walking"})
	done := d.newTrack(me, testTrack{trackType: "walking"})
	theirs := d.newTrack(other, testTrack{trackType: "walking"})
	if _, err := d.pool.Exec(context.Background(), `UPDATE activities SET edit_pending = true WHERE id = ANY($1)`, []string{pending, theirs}); err != nil {
		t.Fatal(err)
	}

	var resp pendingResponse
	d.decode(d.do(me, http.MethodGet, "/v1/activities/pending?ids="+pending+","+done+","+theirs, nil), http.StatusOK, &resp)
	if len(resp.Pending) != 1 || resp.Pending[0] != pending {
		t.Fatalf("pending %v, want only %s", resp.Pending, pending)
	}
	for _, bad := range []string{"", "not-an-id", pending + ","} {
		if rec := d.do(me, http.MethodGet, "/v1/activities/pending?ids="+bad, nil); rec.Code != http.StatusBadRequest {
			t.Errorf("ids=%q: status %d, want 400", bad, rec.Code)
		}
	}
}
