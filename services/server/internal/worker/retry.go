package worker

import (
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgconn"

	"github.com/HoldMyTrack/platform/services/server/internal/storage"

	"github.com/HoldMyTrack/platform/services/server/internal/ingest"
)

// retryDelays are the waits before a job that failed on something passing (a database or
// object-storage error) runs again: the n-th retry waits retryDelays[n-1]. Together they ride
// out an outage of a couple of hours; the run after the last fails for good, except an
// ingest's (retryDelay).
var retryDelays = []time.Duration{time.Minute, 5 * time.Minute, 30 * time.Minute, 2 * time.Hour}

// panicError is a job that panicked: a bug, or a file that trips one, which another run
// would only repeat.
type panicError struct{ value any }

func (e panicError) Error() string { return fmt.Sprintf("panic: %v", e.value) }

// retryable reports whether a job of kind that failed with err may run again. An ingest whose
// file is at fault (its error code isn't FailInternal) fails at once, and so do a panic, a
// value the database refuses (dataError) and an object missing from storage: faults no rerun
// mends, which the "jobs failed on our side" alert reports. A request checks every file it accepts (ingest.Check), so the first
// meets only a job no request checked.
// Track edits aren't retried: a failure already restores the old track and clears Pending, and
// the user can save again. Nor is `reprivacy`, which queues its own reruns
// (ingest.ProcessReprivacy). The kinds retried are safe to run twice.
func retryable(kind string, err error) bool {
	if errors.As(err, new(panicError)) || dataError(err) || storage.IsNotFound(err) {
		return false
	}
	switch kind {
	case "ingest":
		return ingest.FailureCode(err) == ingest.FailInternal
	case "render_fog", "trip_copy", "export", "count_points":
		return true
	}
	return false
}

// retryDelay is how long to wait before running again a job of kind that failed, retried
// retries times before, and false once its retries are spent. An ingest's never are: an
// accepted file stays Pending until it becomes a track (SPEC.md FR-3.1), run again every
// longest delay, and the retrying jobs gauge alerts on it.
func retryDelay(kind string, retries int) (time.Duration, bool) {
	switch {
	case retries < 0:
		return 0, false
	case retries < len(retryDelays):
		return retryDelays[retries], true
	case kind == "ingest":
		return retryDelays[len(retryDelays)-1], true
	}
	return 0, false
}

// dataError reports a Postgres refusal of the values themselves, SQLSTATE class 22 (data
// exception) or 23 (integrity constraint): the same job would be refused again on every run.
func dataError(err error) bool {
	var pe *pgconn.PgError
	return errors.As(err, &pe) && (strings.HasPrefix(pe.Code, "22") || strings.HasPrefix(pe.Code, "23"))
}
