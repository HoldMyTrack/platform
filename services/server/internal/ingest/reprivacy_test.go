package ingest

import (
	"testing"
	"time"
)

func TestReprivacyRetryDelay(t *testing.T) {
	for _, tc := range []struct {
		retry int
		want  time.Duration
		ok    bool
	}{
		{-1, 0, false},
		{0, time.Minute, true},
		{1, 5 * time.Minute, true},
		{len(reprivacyRetryDelays) - 1, reprivacyRetryDelays[len(reprivacyRetryDelays)-1], true},
		{len(reprivacyRetryDelays), 0, false},
	} {
		if got, ok := reprivacyRetryDelay(tc.retry); got != tc.want || ok != tc.ok {
			t.Errorf("reprivacyRetryDelay(%d) = %v, %v, want %v, %v", tc.retry, got, ok, tc.want, tc.ok)
		}
	}
}
