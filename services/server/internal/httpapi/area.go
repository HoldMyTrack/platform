package httpapi

import (
	"math"
	"strconv"
	"strings"
)

// mapArea is a map view, the `bbox` of "Show in this area" (spots_area.go) and of the activity
// list (activity_list.go), as boxes within −180…180: one, or two when the view crosses the
// antimeridian, west[i] to east[i] each, all between south and north.
type mapArea struct {
	south, north float64
	west, east   []float64
}

// boxes is the area as two boxes, west and east edges each, the form both queries take as
// constant parameters: a single box is sent twice.
func (a mapArea) boxes() (w1, e1, w2, e2 float64) {
	last := len(a.west) - 1
	return a.west[0], a.east[0], a.west[last], a.east[last]
}

// parseBBox reads "west,south,east,north" into the boxes it covers. A view across the
// antimeridian comes either way: unwrapped, east past 180 (170,…,190,…, as MapLibre's web
// bounds give it), or wrapped, west > east (170,…,−170,…); both are 170…180 and −180…−170. A
// view 360° wide or more is the whole world.
func parseBBox(raw string) (mapArea, bool) {
	var box [4]float64
	parts := strings.Split(raw, ",")
	if len(parts) != 4 {
		return mapArea{}, false
	}
	for i, p := range parts {
		v, err := strconv.ParseFloat(strings.TrimSpace(p), 64)
		if err != nil || math.IsNaN(v) || math.IsInf(v, 0) {
			return mapArea{}, false
		}
		box[i] = v
	}
	west, east := box[0], box[2]
	area := mapArea{south: math.Max(box[1], -90), north: math.Min(box[3], 90)}
	if area.south >= area.north || west == east {
		return mapArea{}, false
	}
	if west > east {
		east += 360
	}
	if east-west >= 360 {
		area.west, area.east = []float64{-180}, []float64{180}
		return area, true
	}
	// Bring west into −180…180; east then lies within 360° of it.
	shift := 360 * math.Floor((west+180)/360)
	west, east = west-shift, east-shift
	if east <= 180 {
		area.west, area.east = []float64{west}, []float64{east}
	} else {
		area.west, area.east = []float64{west, -180}, []float64{180, east - 360}
	}
	return area, true
}
