package ingest

// Covers docs/SPEC.md FR-3.1 (a file that can't become a track is refused when sent).

import (
	"strings"
	"testing"
	"time"

	"github.com/HoldMyTrack/platform/services/server/internal/parse"
)

func TestCheck(t *testing.T) {
	t0 := time.Date(2026, 6, 1, 8, 0, 0, 0, time.UTC)
	walk := func(n int) []parse.Point {
		points := make([]parse.Point, n)
		for i := range points {
			points[i] = pt(41.5, -81.7+0.0001*float64(i), t0.Add(time.Duration(i)*time.Second))
		}
		return points
	}
	withEle := func(points []parse.Point, ele ...float32) []parse.Point {
		for i := range points {
			e := ele[i%len(ele)]
			points[i].Elevation = &e
		}
		return points
	}
	cases := []struct {
		name string
		act  parse.Track
		want string // a FailureCode, "" for none
	}{
		{"a walk", parse.Track{TrackType: "walk", Points: walk(100)}, ""},
		{"a type of 50 Cyrillic letters", parse.Track{TrackType: strings.Repeat("ж", 50), Points: walk(2)}, ""},
		{"a type of 51 letters", parse.Track{TrackType: strings.Repeat("a", 51), Points: walk(2)}, FailTypeTooLong},
		{"no timestamps", parse.Track{Points: []parse.Point{pt(41.5, -81.7, time.Time{}), pt(41.6, -81.7, time.Time{})}}, FailNoTimestamps},
		{"one valid point", parse.Track{Points: append(walk(1), pt(95, 0, t0.Add(time.Second)))}, FailTooFewPoints},
		{"a climb of 999 km", parse.Track{Points: withEle(walk(2), 0, 999_000)}, ""},
		{"one corrupt elevation", parse.Track{Points: withEle(walk(2), 0, 1e7)}, FailImplausible},
		{"GPS jumps back and forth", parse.Track{Points: func() []parse.Point {
			// 0.2° of latitude is about 22 km: 5,000 jumps are 111,000 km over the same few tiles.
			points := walk(5001)
			for i := range points {
				points[i].Lat = 41.5 + 0.2*float64(i%2)
			}
			return points
		}()}, FailImplausible},
		{"a stray point in 1900", parse.Track{Points: append([]parse.Point{pt(41.5, -81.7, time.Date(1900, 1, 1, 0, 0, 0, 0, time.UTC))}, walk(2)...)}, FailImplausible},
		{"a route across the world", parse.Track{Points: []parse.Point{pt(-70, 0, t0), pt(70, 90, t0.Add(time.Hour)), pt(-70, 179, t0.Add(2*time.Hour))}}, FailTooLarge},
	}
	for _, c := range cases {
		got := ""
		if err := Check(c.act); err != nil {
			got = FailureCode(err)
		}
		if got != c.want {
			t.Errorf("%s: %q, want %q", c.name, got, c.want)
		}
	}
}

func TestCheckFile(t *testing.T) {
	gpx := func(trkpts string) []byte {
		return []byte(`<gpx creator="x"><trk><trkseg>` + trkpts + `</trkseg></trk></gpx>`)
	}
	for _, c := range []struct {
		name, filename string
		data           []byte
		want           string
	}{
		{"a track", "a.gpx", gpx(`<trkpt lat="41.5" lon="-81.7"><time>2026-06-01T08:00:00Z</time></trkpt><trkpt lat="41.5" lon="-81.6"><time>2026-06-01T08:10:00Z</time></trkpt>`), ""},
		{"a planned route", "a.gpx", gpx(`<trkpt lat="41.5" lon="-81.7"/><trkpt lat="41.5" lon="-81.6"/>`), FailNoTimestamps},
		{"cut off", "a.gpx", gpx(`<trkpt lat=`)[:40], FailUnreadableFile},
		{"no points", "a.gpx", gpx(``), FailNoTrack},
	} {
		got := ""
		if err := CheckFile(c.filename, c.data); err != nil {
			got = FailureCode(err)
		}
		if got != c.want {
			t.Errorf("%s: %q, want %q", c.name, got, c.want)
		}
	}
}
