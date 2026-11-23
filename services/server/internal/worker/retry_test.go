package worker

import (
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"

	"github.com/HoldMyTrack/platform/services/server/internal/metrics"
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
		{"trip_copy", outage, true},
		{"export", outage, true},
		{"edit_route", outage, false},
		{"reprivacy", outage, false},
		{"trip_copy", panicError{"nil map"}, false},
		{"ingest", fmt.Errorf("ingest: persist track: %w", &pgconn.PgError{Code: "22021"}), false},
		{"ingest", fmt.Errorf("ingest: persist track: %w", &pgconn.PgError{Code: "23503"}), false},
		{"ingest", fmt.Errorf("ingest: persist track: %w", &pgconn.PgError{Code: "40P01"}), true},
		{"test_unknown", outage, false},
	} {
		if got := retryable(tc.kind, tc.err); got != tc.want {
			t.Errorf("retryable(%s, %v) = %v, want %v", tc.kind, tc.err, got, tc.want)
		}
	}
}

func TestRetryDelay(t *testing.T) {
	for _, tc := range []struct {
		kind    string
		retries int
		want    time.Duration
		ok      bool
	}{
		{"export", -1, 0, false},
		{"export", 0, time.Minute, true},
		{"export", 3, 2 * time.Hour, true},
		{"export", 4, 0, false},
		{"ingest", 0, time.Minute, true},
		{"ingest", 4, 2 * time.Hour, true},
		{"ingest", 1000, 2 * time.Hour, true},
	} {
		if got, ok := retryDelay(tc.kind, tc.retries); got != tc.want || ok != tc.ok {
			t.Errorf("retryDelay(%s, %d) = %v, %v, want %v, %v", tc.kind, tc.retries, got, ok, tc.want, tc.ok)
		}
	}
	if metrics.ScheduledRetries != len(retryDelays) {
		t.Errorf("metrics.ScheduledRetries %d, want the %d retryDelays", metrics.ScheduledRetries, len(retryDelays))
	}
}
