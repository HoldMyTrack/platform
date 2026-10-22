package ingest

import (
	"time"

	"github.com/HoldMyTrack/platform/services/server/internal/parse"
)

// recordedSpan is the stretch of time a recording, or the split piece rng narrows it to, covers
// as recorded: before Private locations clip its ends and before any track edit. It's what the
// hint compares an activity by (recorded_started_at, recorded_ended_at), since another source's
// copy of the same walk still covers the minutes spent inside a Private location. Nil when the
// piece has no points.
func recordedSpan(points []parse.Point, rng SplitRange) (start, end *time.Time) {
	piece := rng.Apply(points, nil)
	if len(piece) == 0 {
		return nil, nil
	}
	return &piece[0].Time, &piece[len(piece)-1].Time
}
