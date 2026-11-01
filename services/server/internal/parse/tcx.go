package parse

import (
	"encoding/xml"
	"fmt"
	"io"
	"strconv"
	"strings"
)

// ParseTCX streams Trackpoint elements. Garmin Training Center XML nests position and
// altitude under a Trackpoint — heart rate too, which is deliberately not read (VISION.md §1.1).
func ParseTCX(r io.Reader) (Activity, error) {
	dec := xml.NewDecoder(r)
	act := Activity{ActivityType: "unknown"}

	// cur is set only between a Trackpoint's start and end, so it is what says an element is
	// inside one. path is only for the innermost element's name: scanning it for "Trackpoint"
	// on every text token made a deeply nested file quadratic to parse.
	var cur *Point
	var haveLat, haveLon bool // cur had a readable latitude, longitude
	var path []string

	for {
		tok, err := dec.Token()
		if err == io.EOF {
			break
		}
		if err != nil {
			return Activity{}, fmt.Errorf("parse tcx: %w", err)
		}

		switch t := tok.(type) {
		case xml.StartElement:
			path = append(path, t.Name.Local)
			switch t.Name.Local {
			case "Activity":
				for _, a := range t.Attr {
					if a.Name.Local == "Sport" {
						act.ActivityType = strings.ToLower(a.Value)
					}
				}
			case "Trackpoint":
				cur, haveLat, haveLon = &Point{}, false, false
			}
		case xml.CharData:
			if cur == nil {
				continue
			}
			text := strings.TrimSpace(string(t))
			if text == "" || len(path) == 0 {
				continue
			}
			leaf := path[len(path)-1]
			switch leaf {
			case "Time":
				if ts, ok := parseTime(text); ok {
					cur.Time = ts
				}
			case "LatitudeDegrees":
				if v, err := strconv.ParseFloat(text, 64); err == nil {
					cur.Lat, haveLat = v, true
				}
			case "LongitudeDegrees":
				if v, err := strconv.ParseFloat(text, 64); err == nil {
					cur.Lon, haveLon = v, true
				}
			case "AltitudeMeters":
				if v, err := strconv.ParseFloat(text, 32); err == nil {
					f := float32(v)
					cur.Elevation = &f
				}
			}
		case xml.EndElement:
			if len(path) > 0 {
				path = path[:len(path)-1]
			}
			if t.Name.Local == "Trackpoint" && cur != nil {
				// Both or neither: one alone would put the point on the equator or the prime
				// meridian, a line across the map.
				if haveLat && haveLon {
					act.Points = append(act.Points, *cur)
				}
				cur = nil
			}
		}
	}

	if len(act.Points) == 0 {
		return Activity{}, fmt.Errorf("parse tcx: %w", ErrNoPoints)
	}
	return act, nil
}
