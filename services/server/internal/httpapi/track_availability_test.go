package httpapi

import "testing"

func TestTrackAvailability(t *testing.T) {
	yes, no := true, false
	for _, tc := range []struct {
		name              string
		a                 trackAvailability
		routeEdit, photos string
	}{
		{"editable", trackAvailability{hasOriginal: true, editableTimes: &yes}, "", ""},
		{"not looked at yet is allowed", trackAvailability{hasOriginal: true}, "", ""},
		{"pending first", trackAvailability{pending: true, private: true}, blockedPending, blockedPrivate},
		{"private", trackAvailability{private: true, hasOriginal: true}, blockedPrivate, blockedPrivate},
		{"no original", trackAvailability{editableTimes: &yes}, blockedNoOriginal, ""},
		{"timestamps that don't run forward", trackAvailability{hasOriginal: true, editableTimes: &no}, blockedBadTimes, ""},
		{"pending allows photos", trackAvailability{pending: true, hasOriginal: true}, blockedPending, ""},
	} {
		if got := tc.a.routeEdit(); got != tc.routeEdit {
			t.Errorf("%s: trackEdit = %q, want %q", tc.name, got, tc.routeEdit)
		}
		if got := tc.a.photos(); got != tc.photos {
			t.Errorf("%s: photos = %q, want %q", tc.name, got, tc.photos)
		}
	}
}
