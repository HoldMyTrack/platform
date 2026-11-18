// Package parse implements the three Path-3 file formats (IMPLEMENTATION.md
// §4.0/§4.1 step 2), each streaming rather than buffering a whole file into memory.
package parse

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"path/filepath"
	"strings"
	"time"
)

// Point is one raw sample. Elevation is a pointer, so a sample without one is told apart from
// one at sea level.
type Point struct {
	Lat       float64
	Lon       float64
	Elevation *float32
	Time      time.Time
}

// Activity is the parsed result, before privacy trimming or simplification (§4.1 steps 3, 5).
type Track struct {
	TrackType string // 'run' | 'ride' | 'hike' | ... — best-effort from the source file
	Points    []Point
	// Name and Description are empty from every file format and from Health Connect sync. Only
	// the app's own recording sets them, through Path 2's JSON wire format (IMPLEMENTATION.md
	// §4.0.4); ingest.Process stores them when non-empty.
	Name        string
	Description string
}

// ErrNoPoints is a file that parsed cleanly but holds no point with a position: an indoor
// workout's FIT file, typically. ErrUnsupportedFormat is an extension no parser here reads.
// Both are the person's file rather than a fault here, so ingest reports each as its own
// failure code (ingest.FailureCode), which the apps show translated.
// ErrTooManyPoints is a file past the cap ByExtensionUpTo was given, refused as the parser
// reaches it rather than after holding them all.
var (
	ErrNoPoints          = errors.New("no track points with a position")
	ErrUnsupportedFormat = errors.New("unrecognized extension")
	ErrTooManyPoints     = fmt.Errorf("more than %d track points", MaxPoints)
)

// MaxPoints bounds a new upload's positioned points (ByExtensionUpTo): two days at one a
// second, past any real track. A 16 MiB FIT file of bare records holds about 1.9 million, half a gigabyte decoded.
const MaxPoints = 200_000

// ByExtensionUpTo dispatches on the uploaded filename's extension and streams from r — callers
// must not read r into memory first (IMPLEMENTATION.md §5.2; a 100-mile ride at 1 Hz is
// 36,000+ points). It refuses a file past maxPoints positioned points with ErrTooManyPoints,
// as soon as the parser reaches it; 0 is no cap. A new upload is held to
// MaxPoints; a stored original is read without one, so one kept before the cap still opens.
func ByExtensionUpTo(filename string, r io.Reader, maxPoints int) (Track, error) {
	switch strings.ToLower(filepath.Ext(filename)) {
	case ".gpx":
		return parseGPX(r, maxPoints)
	case ".tcx":
		return parseTCX(r, maxPoints)
	case ".fit":
		return parseFIT(r, maxPoints)
	case ".json":
		return ParseJSON(r)
	default:
		return Track{}, fmt.Errorf("parse: %w %q", ErrUnsupportedFormat, filepath.Ext(filename))
	}
}

// JSONPoint is one sample of Path 2's batched normalized-points wire format
// (`POST /v2/sync/tracks`, IMPLEMENTATION.md §4.0.3) — exported so
// internal/httpapi can decode the incoming request body straight into the same shape this
// package re-marshals as the raw payload, with no separate wire type to keep in sync.
type JSONPoint struct {
	Lat        float64   `json:"lat"`
	Lon        float64   `json:"lon"`
	ElevationM *float32  `json:"elevation_m,omitempty"`
	Time       time.Time `json:"time"`
}

// ErrPointIncomplete is a JSONPoint without lat, lon or time, which would otherwise read as
// 0, 0 at the zero time.
var ErrPointIncomplete = errors.New(`a point needs "lat", "lon" and "time"`)

// UnmarshalJSON refuses an incomplete point (ErrPointIncomplete) and a field JSONPoint doesn't
// declare.
func (p *JSONPoint) UnmarshalJSON(b []byte) error {
	var raw struct {
		Lat        *float64   `json:"lat"`
		Lon        *float64   `json:"lon"`
		ElevationM *float32   `json:"elevation_m"`
		Time       *time.Time `json:"time"`
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&raw); err != nil {
		return err
	}
	if raw.Lat == nil || raw.Lon == nil || raw.Time == nil {
		return ErrPointIncomplete
	}
	*p = JSONPoint{Lat: *raw.Lat, Lon: *raw.Lon, ElevationM: raw.ElevationM, Time: *raw.Time}
	return nil
}

// JSONActivity is one track's worth of JSONPoint, the stored raw payload of a synced track
// (`internal/httpapi.syncTrackRequest.payload` builds it).
//
// Name and Description are optional and empty for Health Connect/HealthKit sync, which never
// sends them. In-app GPS recording (`source = "recorded"`, `docs/IMPLEMENTATION.md` §4.0.4)
// sets them from its own Name/Description fields, captured before or during a recording, so
// the resulting track carries them from the moment it's created rather than needing a
// separate edit afterward.
type JSONActivity struct {
	TrackType string `json:"track_type"`
	// OldTrackType is the type of a payload stored before migration 0057, which named it
	// activity_type; ParseJSON reads it when TrackType is empty. It goes with the
	// rewrite_sync_payload job once every stored payload says track_type.
	OldTrackType string      `json:"activity_type,omitempty"`
	Points       []JSONPoint `json:"points"`
	Name         string      `json:"name,omitempty"`
	Description  string      `json:"description,omitempty"`
}

// ParseJSON decodes Path 2's normalized-point wire format into the same Activity shape
// GPX/TCX/FIT parsing produces, so ingest.Process needs no Path-2-specific branch — the
// on-device app has already read raw samples out of the platform health store itself, so
// there is no format-specific parsing left to do here, only a field-for-field reshape.
func ParseJSON(r io.Reader) (Track, error) {
	var a JSONActivity
	if err := json.NewDecoder(r).Decode(&a); err != nil {
		return Track{}, fmt.Errorf("parse: decode json: %w", err)
	}
	points := make([]Point, len(a.Points))
	for i, p := range a.Points {
		points[i] = Point{Lat: p.Lat, Lon: p.Lon, Elevation: p.ElevationM, Time: p.Time}
	}
	trackType := a.TrackType
	if trackType == "" {
		trackType = a.OldTrackType
	}
	if trackType == "" {
		trackType = "unknown"
	}
	return Track{TrackType: trackType, Points: points, Name: a.Name, Description: a.Description}, nil
}

// WrapLon brings a longitude into −180…180 (180 itself stays 180): a point of a track stored
// continuing past ±180 across the antimeridian, put back on the world for a file that expects
// it there.
func WrapLon(lon float64) float64 {
	if lon >= -180 && lon <= 180 {
		return lon
	}
	return lon - 360*math.Floor((lon+180)/360)
}

// zonelessLayouts are the timestamp forms some exporters write without a zone; they are read as
// UTC, the zone GPX and TCX both specify.
var zonelessLayouts = []string{"2006-01-02T15:04:05.999999999", "2006-01-02T15:04:05"}

// parseTime reads a GPX or TCX <time>: RFC 3339, else a zoneless timestamp as UTC. Pretty-printed
// files put whitespace around it, which is trimmed.
func parseTime(text string) (time.Time, bool) {
	text = strings.TrimSpace(text)
	if t, err := time.Parse(time.RFC3339Nano, text); err == nil {
		return t, true
	}
	for _, layout := range zonelessLayouts {
		if t, err := time.ParseInLocation(layout, text, time.UTC); err == nil {
			return t, true
		}
	}
	return time.Time{}, false
}
