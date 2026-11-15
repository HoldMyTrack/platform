package httpapi

import (
	"net/http"
	"testing"
)

// The summary totals moving time, as the list, Stories and Trends do, falling back to elapsed
// time only for an activity that has none.
func TestSummaryTotalsMovingTime(t *testing.T) {
	d := newDBTest(t)
	me := d.newAccount(false)
	moving := 1800
	d.newActivity(me, testActivity{activityType: "walking", distanceMeters: 3000, durationSecs: 3600, movingSeconds: &moving})
	d.newActivity(me, testActivity{activityType: "walking", distanceMeters: 1000, durationSecs: 600})
	var summary activitySummaryResponse
	d.decode(d.do(me, http.MethodGet, "/v1/activities/summary", nil), http.StatusOK, &summary)
	if summary.DurationSeconds != 1800+600 {
		t.Fatalf("summary time %d s, want the 1800 s moving plus 600 s elapsed of the one with no moving time", summary.DurationSeconds)
	}
}
