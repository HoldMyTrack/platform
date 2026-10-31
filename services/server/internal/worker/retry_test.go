package worker

import (
	"errors"
	"testing"
	"time"
)

func TestRetryable(t *testing.T) {
	outage := errors.New("storage: connection reset")
	for _, tc := range []struct {
		kind string
		err  error
		want bool
	}{
		{"ingest", outage, true},
		{"ingest", panicError{"index out of range"}, false},
		{"render_fog", outage, true},
		{"story_copy", outage, true},
		{"export", outage, true},
		{"edit_track", outage, false},
		{"reprivacy", outage, false},
		{"story_copy", panicError{"nil map"}, false},
		{"test_unknown", outage, false},
	} {
		if got := retryable(tc.kind, tc.err); got != tc.want {
			t.Errorf("retryable(%s, %v) = %v, want %v", tc.kind, tc.err, got, tc.want)
		}
	}
}

func TestRetryDelay(t *testing.T) {
	for _, tc := range []struct {
		attempt int
		want    time.Duration
		ok      bool
	}{
		{0, 0, false},
		{1, time.Minute, true},
		{4, 2 * time.Hour, true},
		{5, 0, false},
	} {
		if got, ok := retryDelay(tc.attempt); got != tc.want || ok != tc.ok {
			t.Errorf("retryDelay(%d) = %v, %v, want %v, %v", tc.attempt, got, ok, tc.want, tc.ok)
		}
	}
	if maxAttempts != len(retryDelays)+1 {
		t.Errorf("maxAttempts %d, want one run more than the %d retries", maxAttempts, len(retryDelays))
	}
}
