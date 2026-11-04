package httpapi

// Covers docs/SPEC.md FR-5.1 (a row's time is moving time).

import (
	"testing"
	"time"
)

// A row carries moving time, the time Stories and Trends sum, and elapsed time where the
// source gave no moving time.
func TestActivityRowCarriesMovingTime(t *testing.T) {
	d := newDBTest(t)
	me := d.newAccount(false)
	at := [2]float64{-81.60, 41.30}
	moving := 1500
	stopped := d.newActivity(me, testActivity{activityType: "walking", distanceMeters: 3000, durationSecs: 1800, movingSeconds: &moving, at: &at,
		startedAt: time.Date(2026, 5, 1, 9, 0, 0, 0, time.UTC)})
	unset := d.newActivity(me, testActivity{activityType: "walking", distanceMeters: 2000, durationSecs: 1200, at: &at,
		startedAt: time.Date(2026, 5, 2, 9, 0, 0, 0, time.UTC)})

	want := map[string][2]int32{stopped: {1800, 1500}, unset: {1200, 1200}}
	for _, a := range d.listActivities(me) {
		w := want[a.ID]
		if a.DurationSeconds == nil || a.MovingSeconds == nil || *a.DurationSeconds != w[0] || *a.MovingSeconds != w[1] {
			t.Errorf("activity %s: duration %v, moving %v, want %d and %d", a.ID, a.DurationSeconds, a.MovingSeconds, w[0], w[1])
		}
	}
}