package worker

import (
	"errors"
	"fmt"
	"time"

	"github.com/HoldMyTrack/platform/services/server/internal/ingest"
)

// retryDelays are the waits before a job that failed on something passing (a database or
// object-storage error) runs again: the n-th run's failure waits retryDelays[n-1]. Together
// they ride out an outage of a couple of hours; the run after the last fails for good.
var retryDelays = []time.Duration{time.Minute, 5 * time.Minute, 30 * time.Minute, 2 * time.Hour}

// panicError is a job that panicked: a bug, or a file that trips one, which another run
// would only repeat.
type panicError struct{ value any }

func (e panicError) Error() string { return fmt.Sprintf("panic: %v", e.value) }

// retryable reports whether a job of kind that failed with err may run again. An ingest whose
// file is at fault (its error code isn't FailInternal) fails at once, and so does a panic.
// Track edits aren't retried: a failure already restores the old track and clears Pending, and
// the user can save again. Nor is `reprivacy`, which queues its own reruns
// (ingest.ProcessReprivacy). The kinds retried are safe to run twice.
func retryable(kind string, err error) bool {
	if errors.As(err, new(panicError)) {
		return false
	}
	switch kind {
	case "ingest":
		return ingest.FailureCode(err) == ingest.FailInternal
	case "render_fog", "story_copy", "export", "remove_activity_objects":
		return true
	}
	return false
}

// retryDelay is how long to wait before running again a job whose run number attempt (from 1)
// failed, and false once its retries are spent.
func retryDelay(attempt int) (time.Duration, bool) {
	if attempt < 1 || attempt > len(retryDelays) {
		return 0, false
	}
	return retryDelays[attempt-1], true
}
