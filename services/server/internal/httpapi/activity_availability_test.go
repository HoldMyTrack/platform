package httpapi

import "testing"

func TestActivityAvailability(t *testing.T) {
	yes, no := true, false
	for _, tc := range []struct {
		name              string
		a                 activityAvailability
		trackEdit, photos string
	}{
		{"editable", activityAvailability{hasOriginal: true, editableTimes: &yes}, "", ""},
		{"not looked at yet is allowed", activityAvailability{hasOriginal: true}, "", ""},
		{"pending first", activityAvailability{pending: true, private: true}, blockedPending, blockedPrivate},
		{"private", activityAvailability{private: true, hasOriginal: true}, blockedPrivate, blockedPrivate},
		{"no original", activityAvailability{editableTimes: &yes}, blockedNoOriginal, ""},
		{"timestamps that don't run forward", activityAvailability{hasOriginal: true, editableTimes: &no}, blockedBadTimes, ""},
		{"pending allows photos", activityAvailability{pending: true, hasOriginal: true}, blockedPending, ""},
	} {
		if got := tc.a.trackEdit(); got != tc.trackEdit {
			t.Errorf("%s: trackEdit = %q, want %q", tc.name, got, tc.trackEdit)
		}
		if got := tc.a.photos(); got != tc.photos {
			t.Errorf("%s: photos = %q, want %q", tc.name, got, tc.photos)
		}
	}
}
