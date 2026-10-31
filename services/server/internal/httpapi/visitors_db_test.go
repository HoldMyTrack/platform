package httpapi

// Covers docs/SPEC.md FR-12.4 (unique web visitors).

import (
	"context"
	"log/slog"
	"testing"
	"time"
)

func TestVisitorCounterCountsEachVisitorOnceADay(t *testing.T) {
	d := newDBTest(t)
	ctx := context.Background()
	day := time.Date(2001, 5, 6, 0, 0, 0, 0, time.UTC)
	cleanup := func() {
		d.pool.Exec(ctx, `DELETE FROM visitor_days WHERE day = $1`, day)  //nolint:errcheck // best effort
		d.pool.Exec(ctx, `DELETE FROM visitor_salts WHERE day = $1`, day) //nolint:errcheck // best effort
	}
	cleanup()
	t.Cleanup(cleanup)

	at := day.Add(9 * time.Hour)
	d.srv.visitors.record(ctx, at, "203.0.113.7", firefox)
	d.srv.visitors.record(ctx, at.Add(time.Hour), "203.0.113.7", firefox)
	d.srv.visitors.record(ctx, at, "203.0.113.8", firefox)
	// A second process (or a restart) reads the same salt, so the visitor stays one.
	other := &visitorCounter{pool: d.pool, log: slog.New(slog.DiscardHandler)}
	other.record(ctx, at.Add(2*time.Hour), "203.0.113.7", firefox)

	var visitors, salts int
	if err := d.pool.QueryRow(ctx, `SELECT (SELECT count(*) FROM visitor_days WHERE day = $1), (SELECT count(*) FROM visitor_salts WHERE day = $1)`, day).Scan(&visitors, &salts); err != nil {
		t.Fatalf("count: %v", err)
	}
	if visitors != 2 || salts != 1 {
		t.Errorf("%d visitors under %d salts, want 2 under 1", visitors, salts)
	}
}
