package parse

import (
	"encoding/xml"
	"fmt"
	"io"
	"slices"
	"strconv"
	"strings"
	"time"
)

// ParseGPX streams trkpt elements with a token-based decoder rather than xml.Unmarshal into
// a whole-document struct, so a large track never lives in memory as a parsed DOM either.
//
// The points are the track's, in time order, because ClipEnds trims Private locations from
// whichever points come first and last:
//   - A <wpt> is a place marked along the way, not part of the recorded line, so it is never
//     a point; read as one, a waypoint written ahead of the <trk> (where the schema puts it)
//     became the track's start and the real start went unclipped.
//   - Route points (<rtept>) are used only for a file with no track points at all.
//   - Each <trkseg> (or <rte>) is kept whole, and segments are put in order of their first
//     timestamp: a file listing the return leg before the outbound one would otherwise have
//     its start in the middle, where no clip reaches.
//   - A point whose lat or lon is missing or unreadable is skipped, not read as 0.
func ParseGPX(r io.Reader) (Activity, error) {
	dec := xml.NewDecoder(r)
	act := Activity{ActivityType: "unknown"}

	var trkSegs, rteSegs [][]Point
	var cur *Point
	var curKind string  // "trkpt" or "rtept"
	var curValid bool   // cur had both a readable lat and lon
	var curField string // which child element of the current trkpt we're inside, if any
	var inType bool     // inside a <trk>'s or <rte>'s own <type>
	var open []string   // the elements the decoder is inside, innermost last

	for {
		tok, err := dec.Token()
		if err == io.EOF {
			break
		}
		if err != nil {
			return Activity{}, fmt.Errorf("parse gpx: %w", err)
		}

		switch t := tok.(type) {
		case xml.StartElement:
			parent := ""
			if len(open) > 0 {
				parent = open[len(open)-1]
			}
			open = append(open, t.Name.Local)
			switch t.Name.Local {
			case "trkseg":
				trkSegs = append(trkSegs, nil)
			case "rte":
				rteSegs = append(rteSegs, nil)
			case "trkpt", "rtept":
				p := Point{}
				haveLat, haveLon := false, false
				for _, a := range t.Attr {
					var err error
					switch a.Name.Local {
					case "lat":
						p.Lat, err = strconv.ParseFloat(a.Value, 64)
						haveLat = err == nil
					case "lon":
						p.Lon, err = strconv.ParseFloat(a.Value, 64)
						haveLon = err == nil
					}
				}
				cur, curKind, curValid = &p, t.Name.Local, haveLat && haveLon
			case "ele", "time":
				// The decoder strips namespace prefixes (Name.Local), so no prefix matching
				// is needed. Extensions such as gpxtpx:hr are skipped: HoldMyTrack keeps no
				// heart rate (VISION.md §1.1).
				if cur != nil {
					curField = t.Name.Local
				}
			case "type":
				// The optional GPX track type ("Hiking", "Running", ...) — IMPLEMENTATION.md
				// §4.7: activity_type is whatever the source reports, not a controlled
				// vocabulary. Only a <trk>'s or <rte>'s own: a <wpt> has a <type> too
				// ("Summit"), and extension schemas add per-point ones.
				inType = parent == "trk" || parent == "rte"
			}
		case xml.CharData:
			if inType {
				if v := strings.TrimSpace(string(t)); v != "" {
					act.ActivityType = strings.ToLower(v)
				}
				continue
			}
			if cur == nil || curField == "" {
				continue
			}
			text := string(t)
			switch curField {
			case "ele":
				if v, err := strconv.ParseFloat(strings.TrimSpace(text), 32); err == nil {
					f := float32(v)
					cur.Elevation = &f
				}
			case "time":
				if ts, ok := parseTime(text); ok {
					cur.Time = ts
				}
			}
		case xml.EndElement:
			if len(open) > 0 {
				open = open[:len(open)-1]
			}
			switch t.Name.Local {
			case "ele", "time":
				curField = ""
			case "type":
				inType = false
			case "trkpt", "rtept":
				if cur != nil && curValid {
					segs := &trkSegs
					if curKind == "rtept" {
						segs = &rteSegs
					}
					// A point outside any <trkseg>/<rte> (not valid GPX, but cheap to accept)
					// starts a segment of its own.
					if len(*segs) == 0 {
						*segs = append(*segs, nil)
					}
					last := len(*segs) - 1
					(*segs)[last] = append((*segs)[last], *cur)
				}
				cur = nil
			}
		}
	}

	segs := trkSegs
	if countPoints(segs) == 0 {
		segs = rteSegs
	}
	act.Points = inTimeOrder(segs)
	if len(act.Points) == 0 {
		return Activity{}, fmt.Errorf("parse gpx: %w", ErrNoPoints)
	}
	return act, nil
}

func countPoints(segs [][]Point) int {
	n := 0
	for _, s := range segs {
		n += len(s)
	}
	return n
}

// inTimeOrder concatenates segments ordered by their first timestamp, each kept in its own
// order. A segment with no timestamp at all goes last; ingest drops its points anyway.
func inTimeOrder(segs [][]Point) []Point {
	first := func(seg []Point) time.Time {
		for _, p := range seg {
			if !p.Time.IsZero() {
				return p.Time
			}
		}
		return time.Time{}
	}
	slices.SortStableFunc(segs, func(a, b []Point) int {
		ta, tb := first(a), first(b)
		switch {
		case ta.IsZero() && tb.IsZero():
			return 0
		case ta.IsZero():
			return 1
		case tb.IsZero():
			return -1
		}
		return ta.Compare(tb)
	})
	var points []Point
	for _, s := range segs {
		points = append(points, s...)
	}
	return points
}
