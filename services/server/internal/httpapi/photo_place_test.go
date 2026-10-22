package httpapi

import (
	"testing"
	"time"
)

// A track from 10:00 to 11:00 UTC on 2026-05-01.
var (
	trackStart = float64(time.Date(2026, 5, 1, 10, 0, 0, 0, time.UTC).Unix())
	trackEnd   = float64(time.Date(2026, 5, 1, 11, 0, 0, 0, time.UTC).Unix())
)

func at(hour, minute int) *time.Time {
	t := time.Date(2026, 5, 1, hour, minute, 0, 0, time.UTC)
	return &t
}

func TestPhotoMoment(t *testing.T) {
	for _, tc := range []struct {
		name            string
		takenAt, chosen *time.Time
		want            *time.Time
	}{
		{"taken during", at(10, 30), nil, at(10, 30)},
		{"taken just before, clamped to the start", at(9, 57), nil, at(10, 0)},
		{"taken just after, clamped to the end", at(11, 4), nil, at(11, 0)},
		{"taken too long before", at(9, 50), nil, nil},
		{"no capture time", nil, nil, nil},
		{"the choice wins", at(10, 30), at(10, 45), at(10, 45)},
		{"the choice wins even far off, clamped", at(10, 30), at(14, 0), at(11, 0)},
		{"the choice places one the clock can't", at(8, 0), at(10, 5), at(10, 5)},
	} {
		got := photoMoment(trackStart, trackEnd, tc.takenAt, tc.chosen)
		if (got == nil) != (tc.want == nil) || (got != nil && !got.Equal(*tc.want)) {
			t.Errorf("%s: got %v, want %v", tc.name, got, tc.want)
		}
	}
}

func TestClampToSpanRoundsToTheSecond(t *testing.T) {
	got := clampToSpan(time.Date(2026, 5, 1, 10, 30, 0, 600_000_000, time.UTC), trackStart, trackEnd)
	if want := *at(10, 30); !got.Equal(want) || got.Location() != time.UTC {
		t.Errorf("got %v, want %v in UTC", got, want)
	}
}

// A camera clock with no zone is read where the activity was first; failing that, in the UTC
// offset nearest home's that lands on the track, which is the near edge of the offsets that do;
// failing that, where the activity was anyway.
func TestResolveWallClock(t *testing.T) {
	berlin, _ := time.LoadLocation("Europe/Berlin") // UTC+2 in May
	onTrack := func(t time.Time) bool { return nearTrack(t, trackStart, trackEnd) }
	wall := func(day, hour int) time.Time { return time.Date(2026, 5, day, hour, 30, 0, 0, time.UTC) }
	for _, tc := range []struct {
		name string
		wall time.Time
		want time.Time
	}{
		{"home's zone places it", wall(1, 12), *at(10, 30)},
		// Read at 10:30 UTC by a camera on UTC, but +00:30 is the landing offset nearest +02:00.
		{"a camera on UTC", wall(1, 10), *at(10, 0)},
		{"nothing places it: home's reading", wall(3, 3), time.Date(2026, 5, 3, 3, 30, 0, 0, berlin)},
	} {
		got := resolveWallClock(tc.wall, berlin, onTrack)
		if !got.Equal(tc.want) {
			t.Errorf("%s: got %v, want %v", tc.name, got, tc.want)
		}
	}
}

func TestParsePhotoClockAndPosition(t *testing.T) {
	if c, err := parsePhotoClock("2026-05-01T10:30:00+02:00", "2026-05-01T10:30:00"); err != nil || c.at == nil || c.local != nil {
		t.Errorf("an instant wins over a wall clock: %+v %v", c, err)
	}
	if c, err := parsePhotoClock("", "2026-05-01T10:30:00"); err != nil || c.at != nil || c.local == nil {
		t.Errorf("a wall clock alone: %+v %v", c, err)
	}
	if c, err := parsePhotoClock("", ""); err != nil || c.at != nil || c.local != nil {
		t.Errorf("neither: %+v %v", c, err)
	}
	for _, bad := range [][2]string{{"10:30", ""}, {"", "2026-05-01 10:30"}} {
		if _, err := parsePhotoClock(bad[0], bad[1]); err == nil {
			t.Errorf("%q: parsed, want refused", bad)
		}
	}

	if p, err := parsePhotoPosition("13.4", "52.5"); err != nil || p == nil || p[0] != 13.4 || p[1] != 52.5 {
		t.Errorf("a position: %v %v", p, err)
	}
	if p, err := parsePhotoPosition("13.4", ""); err != nil || p != nil {
		t.Errorf("one coordinate is no position: %v %v", p, err)
	}
	for _, bad := range [][2]string{{"181", "0"}, {"0", "-91"}, {"east", "52"}} {
		if _, err := parsePhotoPosition(bad[0], bad[1]); err == nil {
			t.Errorf("%q: parsed, want refused", bad)
		}
	}
}
