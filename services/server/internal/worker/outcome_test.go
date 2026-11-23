package worker

import (
	"context"
	"errors"
	"log/slog"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/HoldMyTrack/platform/services/server/internal/storage"
)

// A run's outcome write that fails on something passing is tried again until it gets through,
// so the run doesn't read as a crash; one Postgres refuses, or one cut off by a shutdown, isn't.
func TestRecordOutcome(t *testing.T) {
	saved := outcomeBackoff
	outcomeBackoff = [2]time.Duration{time.Millisecond, 2 * time.Millisecond}
	t.Cleanup(func() { outcomeBackoff = saved })
	log := slog.New(slog.DiscardHandler)
	down := errors.New("dial tcp: connection refused")
	updated := pgconn.NewCommandTag("UPDATE 1")
	none := pgconn.NewCommandTag("UPDATE 0")

	for _, c := range []struct {
		name      string
		results   []error // one per try; past the end, success
		tag       pgconn.CommandTag
		cancelled bool
		calls     int
		owned     bool
		fails     bool
	}{
		{"recorded at once", nil, updated, false, 1, true, false},
		{"database down twice", []error{down, down}, updated, false, 3, true, false},
		{"database starting up", []error{&pgconn.PgError{Code: "57P03"}}, updated, false, 2, true, false},
		{"refused by Postgres", []error{&pgconn.PgError{Code: "22021"}}, updated, false, 1, false, true},
		{"claimed again meanwhile", nil, none, false, 1, false, false},
		{"shutting down", []error{down, down}, updated, true, 1, false, true},
	} {
		ctx, cancel := context.WithCancel(context.Background())
		if c.cancelled {
			cancel()
		}
		calls := 0
		exec := func(context.Context, string, ...any) (pgconn.CommandTag, error) {
			calls++
			if calls <= len(c.results) {
				return pgconn.CommandTag{}, c.results[calls-1]
			}
			return c.tag, nil
		}
		owned, err := recordOutcome(ctx, exec, log, 1, "test", "UPDATE")
		cancel()
		if calls != c.calls || owned != c.owned || (err != nil) != c.fails {
			t.Errorf("%s: %d tries, owned %v, err %v; want %d, %v, failing %v", c.name, calls, owned, err, c.calls, c.owned, c.fails)
		}
	}
}

// A run whose job was claimed again while it ran (its lease ran out) records nothing: the
// outcome write names the claim it came from, and the job stays the other claim's.
func TestOutcomeOfAnOutdatedClaimIsDropped(t *testing.T) {
	pool, userID := testPool(t)
	log := slog.New(slog.DiscardHandler)
	ctx := context.Background()
	id := insertJob(t, pool, userID, "2000-01-01T00:00:00Z", 0, nil)

	jobRunner = func(ctx context.Context, pool *pgxpool.Pool, _ *storage.Store, _ *slog.Logger, j job) error {
		// Another loop's claim, after this one's lease ran out.
		_, err := pool.Exec(ctx, `UPDATE jobs SET attempts = attempts + 1, locked_at = NOW() WHERE id = $1`, j.id)
		return err
	}
	t.Cleanup(func() { jobRunner = runJob })

	if _, err := claimAndRunOne(ctx, pool, nil, log); err != nil {
		t.Fatal(err)
	}
	if r := readJob(t, pool, id); r.state != "pending" || r.attempts != 2 {
		t.Errorf("job %+v, want pending under the other claim", r)
	}
}
