package ingest

import (
	"bytes"
	"errors"
	"fmt"
	"math"
	"runtime/debug"
	"unicode/utf8"

	"github.com/HoldMyTrack/platform/services/server/internal/parse"
)

// MaxTrackTypeLen is tracks.track_type's VARCHAR(50).
const MaxTrackTypeLen = 50

// The largest values the tracks columns computeMetrics fills can hold: distance_meters is
// numeric(10,2), elevation_gain_m numeric(8,2), duration_seconds and moving_seconds integer.
const (
	maxDistanceM      = 99_999_999
	maxElevationGainM = 999_999
	maxDurationS      = math.MaxInt32
)

// ErrTypeTooLong is a file whose own type is longer than MaxTrackTypeLen.
var ErrTypeTooLong = fmt.Errorf("the track type is longer than %d characters", MaxTrackTypeLen)

// errImplausible is a recording whose distance, climb or duration no column can hold: a
// corrupt elevation, GPS jumps back and forth, or a stray point decades away.
var errImplausible = errors.New("the distance, climb or duration is beyond any real track")

// CheckFile parses a file as ingest will and runs Check on it. A request runs it before
// accepting the file (SPEC.md FR-3.1); its errors classify with FailureCode. A parser that
// panics on the file has failed to read it: the file is refused as unreadable, with the panic
// in the error for the log.
func CheckFile(filename string, data []byte) (err error) {
	defer func() {
		if r := recover(); r != nil {
			err = parseError{fmt.Errorf("parser panicked: %v\n%s", r, debug.Stack())}
		}
	}()
	act, err := parse.ByExtensionUpTo(filename, bytes.NewReader(data), parse.MaxPoints)
	if err != nil {
		return parseError{err}
	}
	return Check(act)
}

// Check fails a parsed recording that ingest would fail on for its own sake, so nothing
// accepted fails later except on our side (IMPLEMENTATION.md §4.1). It checks the points before
// Private locations: clipping keeps a stretch of them, so it can only shrink the tiles and
// metrics checked here.
func Check(act parse.Track) error {
	points, err := recordedPoints(act.Points)
	if err != nil {
		return err
	}
	return checkRecorded(act.TrackType, points)
}

// recordedPoints keeps the points every reader can use (keepValid, keepTimed), and fails with
// fewer than 2.
func recordedPoints(points []parse.Point) ([]parse.Point, error) {
	points, err := keepTimed(keepValid(points))
	if err != nil {
		return nil, err
	}
	if len(points) < 2 {
		return nil, fmt.Errorf("ingest: %w (%d)", errTooFewPoints, len(points))
	}
	return points, nil
}

// checkRecorded is Check after recordedPoints.
func checkRecorded(trackType string, points []parse.Point) error {
	if utf8.RuneCountInString(trackType) > MaxTrackTypeLen {
		return ErrTypeTooLong
	}
	points = unwrapLons(points)
	if _, err := computeTouchedTiles(points, FogZoom); err != nil {
		return err
	}
	if !fitsColumns(computeMetrics(points, nil)) {
		return errImplausible
	}
	return nil
}

// fitsColumns reports whether m fits the tracks columns it is stored in. A route edit only
// removes points, so it never grows past what the whole recording passed.
func fitsColumns(m metrics) bool {
	return m.distanceM <= maxDistanceM && m.elevationGainM <= maxElevationGainM &&
		m.durationS >= -maxDurationS && m.durationS <= maxDurationS
}
