package httpapi

import (
	"net/http"
	"strings"
	"testing"

	"github.com/HoldMyTrack/platform/services/server/internal/tracktype"
)

// What a client shows for each type (docs/SPEC.md FR-5.1): once per type in the list, and for
// the catalog and any named types on request; and every type the account uses, most first
// (FR-5.5), another account's left out.
func TestTrackTypes(t *testing.T) {
	d := newDBTest(t)
	me := d.newAccount(false)
	d.newTrack(me, testTrack{trackType: "gravel_cycling"})
	d.newTrack(me, testTrack{trackType: "gravel_cycling"})
	d.newTrack(me, testTrack{trackType: "Solowheel"})
	other := d.newAccount(false)
	d.newTrack(other, testTrack{trackType: "kayaking"})

	var list tracksResponse
	d.decode(d.do(me, http.MethodGet, "/v2/tracks", nil), http.StatusOK, &list)
	if len(list.Types) != 2 || list.Types["gravel_cycling"].Kind != tracktype.Wheels || list.Types["Solowheel"].Kind != tracktype.Solowheel {
		t.Fatalf("list types %+v", list.Types)
	}

	var described trackTypesResponse
	d.decode(d.do(me, http.MethodGet, "/v2/track-types?types=evening_jog,kite", nil), http.StatusOK, &described)
	if described.Types["walking"].Kind != tracktype.Foot || described.Types["evening_jog"].Kind != tracktype.Foot || described.Types["kite"].Kind != tracktype.Other ||
		described.Types["evening_jog"].Label != "Evening Jog" || described.Types["walking"].Label != "Walking" {
		t.Fatalf("described %+v", described.Types)
	}
	want := []typeCount{{Type: "gravel_cycling", Count: 2}, {Type: "Solowheel", Count: 1}}
	if len(described.Used) != len(want) || described.Used[0] != want[0] || described.Used[1] != want[1] {
		t.Fatalf("used %+v, want %+v", described.Used, want)
	}
	if described.Types["Solowheel"].Kind != tracktype.Solowheel {
		t.Fatalf("a used type undescribed: %+v", described.Types)
	}
	var fresh trackTypesResponse
	d.decode(d.do(d.newAccount(false), http.MethodGet, "/v2/track-types", nil), http.StatusOK, &fresh)
	if fresh.Used == nil || len(fresh.Used) != 0 {
		t.Fatalf("a new account's used %#v, want []", fresh.Used)
	}
	for _, bad := range []string{"a,,b", strings.Repeat("x", 51), strings.Repeat("a,", 100) + "a"} {
		if rec := d.do(me, http.MethodGet, "/v2/track-types?types="+bad, nil); rec.Code != http.StatusBadRequest {
			t.Errorf("types=%.20s…: status %d, want 400", bad, rec.Code)
		}
	}
}
