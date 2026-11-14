// Package imagery decides whether satellite imagery is offered to everyone (docs/SPEC.md
// FR-4.10, docs/IMPLEMENTATION.md §4.26). The deployment's MapTiler plan pauses its tiles once a
// month's requests are used up, and a map in Satellite mode then hides its fills over nothing; so
// the worker reads the month's usage from MapTiler, probes one tile, and pauses imagery before the
// plan does. The decision is Decide's, a function of what was read; the worker job is Watch.
package imagery

import "time"

// PauseShare is the share of the plan's monthly requests at which imagery is paused for
// everyone: early enough that the usage read's interval doesn't run past the plan's limit.
const PauseShare = 0.95

// ProbeFailuresToPause is how many probes in a row must fail before imagery is paused: one
// network blip shouldn't take Satellite away for an hour.
const ProbeFailuresToPause = 2

// Why imagery is paused.
const (
	ReasonQuota = "quota" // the month's requests reached PauseShare of the plan's
	ReasonProbe = "probe" // the tile probe failed ProbeFailuresToPause times in a row
)

// Status is the decision as stored: Used and Limit are nil when the usage wasn't read.
type Status struct {
	Available bool
	Reason    string
	Used      *int64
	Limit     *int64
	CheckedAt time.Time
}

// Decide is whether imagery is offered, and why not: paused when the month's requests reached
// PauseShare of limit (both known, limit positive), or when the probe has failed
// ProbeFailuresToPause times in a row. The quota wins when both hold.
func Decide(used, limit *int64, probeFailures int) (available bool, reason string) {
	if used != nil && limit != nil && *limit > 0 && float64(*used) >= PauseShare*float64(*limit) {
		return false, ReasonQuota
	}
	if probeFailures >= ProbeFailuresToPause {
		return false, ReasonProbe
	}
	return true, ""
}
