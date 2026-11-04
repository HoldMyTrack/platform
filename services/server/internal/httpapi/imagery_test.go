package httpapi

import (
	"testing"

	"github.com/HoldMyTrack/platform/services/server/internal/imagery"
)

func TestImageryOffered(t *testing.T) {
	for _, tc := range []struct {
		name       string
		configured bool
		stored     imagery.Status
		found      bool
		want       bool
	}{
		{"no imagery configured", false, imagery.Status{Available: true}, true, false},
		{"configured, nothing decided yet", true, imagery.Status{}, false, true},
		{"configured and available", true, imagery.Status{Available: true}, true, true},
		{"configured but paused", true, imagery.Status{Available: false, Reason: imagery.ReasonQuota}, true, false},
	} {
		if got := imageryOffered(tc.configured, tc.stored, tc.found); got != tc.want {
			t.Errorf("%s: %v, want %v", tc.name, got, tc.want)
		}
	}
}
