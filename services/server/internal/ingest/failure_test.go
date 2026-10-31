package ingest

// Covers docs/SPEC.md FR-3.1 (why an import fails).

import (
	"errors"
	"fmt"
	"io"
	"strings"
	"testing"
	"testing/iotest"

	"github.com/HoldMyTrack/platform/services/server/internal/parse"
)

func TestFailureCode(t *testing.T) {
	// parsed runs a real parser, wrapped the way loadClippedPoints wraps its error.
	parsed := func(filename, body string) error {
		_, err := parse.ByExtension(filename, strings.NewReader(body))
		if err == nil {
			t.Fatalf("%s: parse succeeded, want an error", filename)
		}
		return parseError{err}
	}
	cases := []struct {
		name string
		err  error
		want string
	}{
		{"unknown extension", parsed("ride.kml", "<kml/>"), FailUnsupportedFormat},
		{"malformed GPX", parsed("ride.gpx", "<gpx><trk><trkseg><trkpt lat="), FailUnreadableFile},
		{"GPX with no points", parsed("ride.gpx", "<gpx><trk><trkseg></trkseg></trk></gpx>"), FailNoTrack},
		{"FIT with a bad signature", parsed("ride.fit", strings.Repeat("\x00", 14)), FailUnreadableFile},
		{"no timestamps", errNoTimestamps, FailNoTimestamps},
		{"too few points", fmt.Errorf("ingest: %w (%d)", errTooFewPoints, 1), FailTooFewPoints},
		{"a later pipeline step", fmt.Errorf("ingest: persist activity: %w", errors.New("connection reset")), FailInternal},
	}
	for _, c := range cases {
		if got := FailureCode(c.err); got != c.want {
			t.Errorf("%s: FailureCode(%v) = %q, want %q", c.name, c.err, got, c.want)
		}
	}
}

// A storage read that breaks mid-file is ours (FailInternal, so the worker retries it); a file
// read whole that its parser can't read is the file's.
func TestObjectReaderTellsAStorageFailureFromABadFile(t *testing.T) {
	classify := func(r io.Reader) string {
		src := &objectReader{r: r}
		_, err := parseByExtensionReader("ride.gpx", src)
		if err == nil {
			t.Fatal("parse succeeded, want an error")
		}
		if src.err != nil {
			return FailureCode(fmt.Errorf("ingest: read raw payload: %w", src.err))
		}
		return FailureCode(parseError{err})
	}
	broken := io.MultiReader(strings.NewReader(`<gpx><trk><trkseg><trkpt lat="1" lon="2">`), iotest.ErrReader(errors.New("connection reset")))
	if got := classify(broken); got != FailInternal {
		t.Errorf("storage failure mid-file: %s, want %s", got, FailInternal)
	}
	if got := classify(strings.NewReader(`<gpx><trk><trkseg><trkpt lat=`)); got != FailUnreadableFile {
		t.Errorf("malformed file: %s, want %s", got, FailUnreadableFile)
	}
}
