package worker

import (
	"context"
	"errors"
	"log/slog"
	"net"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/HoldMyTrack/platform/services/server/internal/storage"
)

// A run's outcome write that fails on something passing is tried again until it gets through,
// and for outcomeGrace once the worker is stopping, so the run doesn't read as a crash; one
// Postgres refuses, or one the client can't send, isn't.
func TestRecordOutcome(t *testing.T) {
	savedBackoff, savedGrace := outcomeBackoff, outcomeGrace
	outcomeBackoff = [2]time.Duration{time.Millisecond, 2 * time.Millisecond}
	outcomeGrace = 20 * time.Millisecond
	t.Cleanup(func() { outcomeBackoff, outcomeGrace = savedBackoff, savedGrace })
	log := slog.New(slog.DiscardHandler)
	down := &net.OpError{Op: "dial", Net: "tcp", Err: errors.New("connection refused")}
	updated := pgconn.NewCommandTag("UPDATE 1")
	none := pgconn.NewCommandTag("UPDATE 0")

	for _, c := range []struct {
		name      string
		results   []error // one per try; past the end, success
		always    bool    // every try fails with the last of results
		tag       pgconn.CommandTag
		cancelled bool
		calls     int // 0: more than one, however many fit in the grace
		owned     bool
		fails     bool
	}{
		{"recorded at once", nil, false, updated, false, 1, true, false},
		{"database down twice", []error{down, down}, false, updated, false, 3, true, false},
		{"database starting up", []error{&pgconn.PgError{Code: "57P03"}}, false, updated, false, 2, true, false},
		{"refused by Postgres", []error{&pgconn.PgError{Code: "22021"}}, false, updated, false, 1, false, true},
		{"not sent by the client", []error{errors.New("failed to encode args[2]")}, false, updated, false, 1, false, true},
		{"claim no longer held", nil, false, none, false, 1, false, false},
		{"stopping, database back in the grace", []error{down, down}, false, updated, true, 3, true, false},
		{"stopping, database down through the grace", []error{down}, true, updated, true, 0, false, true},
	} {
		ctx, cancel := context.WithCancel(context.Background())
		if c.cancelled {
			cancel()
		}
		calls := 0
		exec := func(context.Context, string, ...any) (pgconn.CommandTag, error) {
			calls++
			if c.always {
				return pgconn.CommandTag{}, c.results[len(c.results)-1]
			}
			if calls <= len(c.results) {
				return pgconn.CommandTag{}, c.results[calls-1]
			}
			return c.tag, nil
		}
		owned, err := recordOutcome(ctx, exec, log, 1, "test", "UPDATE")
		cancel()
		wrongCalls := calls != c.calls
		if c.calls == 0 {
			wrongCalls = calls < 2
		}
		if wrongCalls || owned != c.owned || (err != nil) != c.fails {
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
