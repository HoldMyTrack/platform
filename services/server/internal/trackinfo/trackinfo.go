// Package trackinfo is the text of the Tracks toolbar's Info (docs/SPEC.md FR-5.8): a label and a
// value per line for one track or a group, in the account's units and language, so every client
// shows the same lines and only lays them out.
package trackinfo

import (
	"math"
	"strconv"
	"time"

	"github.com/HoldMyTrack/platform/services/server/internal/i18n"
	"github.com/HoldMyTrack/platform/services/server/internal/ingest"
	"github.com/HoldMyTrack/platform/services/server/internal/tracktype"
	"github.com/HoldMyTrack/platform/services/server/internal/web"
	"github.com/HoldMyTrack/platform/services/server/internal/zoneinfo"
)

// Track is one track as the tracks table has it.
type Track struct {
	Type      string
	StartedAt time.Time
	Timezone  string
	// DurationSeconds is the elapsed time, start to end.
	DurationSeconds *int32
	// MovingSeconds is the source's moving time, null where it gave none.
	MovingSeconds  *int32
	DistanceMeters *float64
	ElevationGainM *float64
	// Private is a track entirely inside Private locations: no route, distance or time.
	Private bool
}

// Line is one line of Info.
type Line struct {
	Label string `json:"label"`
	Value string `json:"value"`
}

// Info is what Info shows: its lines, and a note under them, "" for none.
type Info struct {
	Lines []Line `json:"lines"`
	Note  string `json:"note"`
}

const metersPerMile = 1609.344

// Of is Info for tracks, newest first: one track's own lines, or a group's totals.
func Of(tracks []Track, l *i18n.Localizer, imperial bool) Info {
	if len(tracks) == 1 {
		return one(tracks[0], l, imperial)
	}
	return group(tracks, l, imperial)
}

func one(a Track, l *i18n.Localizer, imperial bool) Info {
	lines := []Line{
		{l.T("track_info.type"), tracktype.Label(a.Type, l.Lang())},
		{l.T("track_info.start"), when(l, a.StartedAt, a.Timezone)},
	}
	if a.Private {
		return Info{Lines: lines, Note: l.T("track_info.private")}
	}
	if a.DurationSeconds != nil {
		lines = append(lines, Line{l.T("track_info.end"), when(l, a.StartedAt.Add(time.Duration(*a.DurationSeconds)*time.Second), a.Timezone)})
	}
	if a.DistanceMeters != nil {
		lines = append(lines, Line{l.T("track_info.distance"), web.FormatDistance(l, *a.DistanceMeters, imperial)})
	}
	note := ""
	if a.MovingSeconds != nil {
		lines = append(lines, Line{l.T("track_info.moving"), web.FormatDuration(l, int64(*a.MovingSeconds))})
		note = movingNote(l, imperial)
	}
	if a.DurationSeconds != nil {
		lines = append(lines, Line{l.T("track_info.elapsed"), web.FormatDuration(l, int64(*a.DurationSeconds))})
	}
	if secs := shownSeconds(a); a.DistanceMeters != nil && secs != nil {
		if line, ok := paceOrSpeed(l, a.Type, *a.DistanceMeters, *secs, imperial); ok {
			lines = append(lines, line)
		}
	}
	if a.ElevationGainM != nil {
		if e := web.FormatElevation(l, *a.ElevationGainM, imperial); e != web.FormatElevation(l, 0, imperial) {
			lines = append(lines, Line{l.T("track_info.elevation"), e})
		}
	}
	return Info{Lines: lines, Note: note}
}

// group is the totals over tracks: Private ones count as tracks and add nothing else, as on the
// stats card (statscard.Values).
func group(tracks []Track, l *i18n.Localizer, imperial bool) Info {
	lines := []Line{{l.T("track_info.tracks"), l.Int(int64(len(tracks)))}}
	var first, last *Track
	var lastEnd time.Time
	var dist, elev float64
	var moving, elapsed int64
	anyMoving := false
	for i := range tracks {
		a := &tracks[i]
		if first == nil || a.StartedAt.Before(first.StartedAt) {
			first = a
		}
		end := a.StartedAt
		if a.DurationSeconds != nil && !a.Private {
			end = end.Add(time.Duration(*a.DurationSeconds) * time.Second)
		}
		if last == nil || end.After(lastEnd) {
			last, lastEnd = a, end
		}
		if a.Private {
			continue
		}
		if a.DistanceMeters != nil {
			dist += *a.DistanceMeters
		}
		if a.MovingSeconds != nil {
			moving += int64(*a.MovingSeconds)
			anyMoving = true
		}
		if a.DurationSeconds != nil {
			elapsed += int64(*a.DurationSeconds)
		}
		if a.ElevationGainM != nil {
			elev += *a.ElevationGainM
		}
	}
	if first != nil {
		lines = append(lines,
			Line{l.T("track_info.from"), when(l, first.StartedAt, first.Timezone)},
			Line{l.T("track_info.to"), when(l, lastEnd, last.Timezone)},
		)
	}
	if dist > 0 {
		lines = append(lines, Line{l.T("track_info.distance"), web.FormatTotalDistance(l, dist, imperial)})
	}
	note := ""
	if anyMoving && moving > 0 {
		lines = append(lines, Line{l.T("track_info.moving"), web.FormatDuration(l, moving)})
		note = movingNote(l, imperial)
	}
	if elapsed > 0 {
		lines = append(lines, Line{l.T("track_info.elapsed"), web.FormatDuration(l, elapsed)})
	}
	if e := web.FormatElevation(l, elev, imperial); e != web.FormatElevation(l, 0, imperial) {
		lines = append(lines, Line{l.T("track_info.elevation"), e})
	}
	return Info{Lines: lines, Note: note}
}

// shownSeconds is the time a row shows: moving time, else the elapsed duration.
func shownSeconds(a Track) *int32 {
	if a.MovingSeconds != nil {
		return a.MovingSeconds
	}
	return a.DurationSeconds
}

// paceOrSpeed is a pace for a foot type, "8:47 /km", and a speed for every other, "18.4 km/h",
// over the row's time; false when either is zero.
func paceOrSpeed(l *i18n.Localizer, trackType string, meters float64, secs int32, imperial bool) (Line, bool) {
	if meters <= 0 || secs <= 0 {
		return Line{}, false
	}
	unit := 1000.0
	if imperial {
		unit = metersPerMile
	}
	if tracktype.KindOf(trackType) == tracktype.Foot {
		perUnit := int64(math.Round(float64(secs) / (meters / unit)))
		v := strconv.FormatInt(perUnit/60, 10) + ":" + pad2(perUnit%60)
		key := "unit.pace.km"
		if imperial {
			key = "unit.pace.mi"
		}
		return Line{l.T("track_info.pace"), l.T(key, "v", v)}, true
	}
	speed := meters / unit / (float64(secs) / 3600)
	key := "unit.speed.kmh"
	if imperial {
		key = "unit.speed.mph"
	}
	return Line{l.T("track_info.speed"), l.T(key, "v", l.Float(speed, 1))}, true
}

func movingNote(l *i18n.Localizer, imperial bool) string {
	key, v := "unit.speed.kmh", ingest.MovingSpeedThresholdMps*3.6
	if imperial {
		key, v = "unit.speed.mph", ingest.MovingSpeedThresholdMps*3600/metersPerMile
	}
	return l.T("track_info.moving_note", "speed", l.T(key, "v", l.Float(v, 1)))
}

// when is a date and time in zone: "Sep 27, 2026, 7:12 AM" / "27 сент. 2026 г., 07:12". A zone
// Go can't load reads as UTC.
func when(l *i18n.Localizer, at time.Time, zone string) string {
	loc, err := zoneinfo.Load(zone)
	if err != nil || zone == "" {
		loc = time.UTC
	}
	t := at.In(loc)
	return web.ShortDateYear(l, t.Format("2006-01-02")) + ", " + t.Format(l.T("track_info.time_layout"))
}

func pad2(n int64) string {
	if n < 10 {
		return "0" + strconv.FormatInt(n, 10)
	}
	return strconv.FormatInt(n, 10)
}
