package httpapi

// Why a track's Edit window tabs can't be used (docs/SPEC.md FR-5.7, FR-15.1), as the
// track list's track_edit and photos codes. Empty is allowed. The clients map a code to their
// own message and add the one rule that depends on the selection: exactly one track checked.
const (
	blockedPending    = "pending"
	blockedPrivate    = "private"
	blockedNoOriginal = "no_original"
	blockedBadTimes   = "bad_times"
)

// trackAvailability is what the list reports from a row's stored state. editableTimes is
// NULL until ingest or a reprocess has looked: an unknown is allowed, and the points request
// still refuses.
type trackAvailability struct {
	pending, private, hasOriginal bool
	editableTimes                 *bool
}

// routeEdit is why Edit track can't open, first reason first.
func (a trackAvailability) routeEdit() string {
	switch {
	case a.pending:
		return blockedPending
	case a.private:
		return blockedPrivate
	case !a.hasOriginal:
		return blockedNoOriginal
	case a.editableTimes != nil && !*a.editableTimes:
		return blockedBadTimes
	}
	return ""
}

// photos is why photos can't be added: they sit on the track, which a private track hides.
func (a trackAvailability) photos() string {
	if a.private {
		return blockedPrivate
	}
	return ""
}
