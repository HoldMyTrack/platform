package httpapi

import (
	"net/http"
	"strings"
	"testing"

	"github.com/HoldMyTrack/platform/services/server/internal/activitytype"
)

// What a client shows for each type (docs/SPEC.md FR-5.1): once per type in the list, and for
// the catalog and any named types on request.
func TestActivityTypes(t *testing.T) {
	d := newDBTest(t)
	me := d.newAccount(false)
	d.newActivity(me, testActivity{activityType: "gravel_cycling"})
	d.newActivity(me, testActivity{activityType: "gravel_cycling"})
	d.newActivity(me, testActivity{activityType: "Solowheel"})

	var list activitiesResponse
	d.decode(d.do(me, http.MethodGet, "/v1/activities", nil), http.StatusOK, &list)
	if len(list.Types) != 2 || list.Types["gravel_cycling"].Kind != activitytype.Wheels || list.Types["Solowheel"].Kind != activitytype.Solowheel {
		t.Fatalf("list types %+v", list.Types)
	}

	var described activityTypesResponse
	d.decode(d.do(me, http.MethodGet, "/v1/activity-types?types=evening_jog,kite", nil), http.StatusOK, &described)
	if described.Types["walking"].Kind != activitytype.Foot || described.Types["evening_jog"].Kind != activitytype.Foot || described.Types["kite"].Kind != activitytype.Other ||
		described.Types["evening_jog"].Label != "Evening Jog" || described.Types["walking"].Label != "Walking" {
		t.Fatalf("described %+v", described.Types)
	}
	for _, bad := range []string{"a,,b", strings.Repeat("x", 51), strings.Repeat("a,", 100) + "a"} {
		if rec := d.do(me, http.MethodGet, "/v1/activity-types?types="+bad, nil); rec.Code != http.StatusBadRequest {
			t.Errorf("types=%.20s…: status %d, want 400", bad, rec.Code)
		}
	}
}
