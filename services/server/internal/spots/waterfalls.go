package spots

import (
	"encoding/json"
	"fmt"
	"math"
)

// viewpointNearM is how close a viewpoint leaves a waterfall out of the import (docs/SPEC.md
// FR-15.1): the viewpoint's badge already leads there.
const viewpointNearM = 120

// waterfallRadiusM is the radius of a waterfall's area, whatever its OSM geometry. OSM puts a
// waterfall on the stream, often at its brink, and people watch it from a trail below or beside.
const waterfallRadiusM = 75

// radiusM is the radius of the circle that stands for a place's area when OSM maps it as a point.
func radiusM(category string) float64 {
	if category == "waterfall" {
		return waterfallRadiusM
	}
	return pointRadiusM
}

type lonLat struct{ lon, lat float64 }

// anchor is where a place is for the waterfall rule: a point's position, or the mean of the
// first outer ring's vertices for an outline.
func anchor(geometry string) (lonLat, bool) {
	var g struct {
		Type        string          `json:"type"`
		Coordinates json.RawMessage `json:"coordinates"`
	}
	if json.Unmarshal([]byte(geometry), &g) != nil {
		return lonLat{}, false
	}
	var ring [][]float64
	switch g.Type {
	case "Point":
		var p []float64
		if json.Unmarshal(g.Coordinates, &p) != nil {
			return lonLat{}, false
		}
		ring = [][]float64{p}
	case "Polygon":
		var rings [][][]float64
		if json.Unmarshal(g.Coordinates, &rings) != nil || len(rings) == 0 {
			return lonLat{}, false
		}
		ring = rings[0]
	case "MultiPolygon":
		var polygons [][][][]float64
		if json.Unmarshal(g.Coordinates, &polygons) != nil || len(polygons) == 0 || len(polygons[0]) == 0 {
			return lonLat{}, false
		}
		ring = polygons[0][0]
	}
	var sum lonLat
	n := 0
	for _, p := range ring {
		if len(p) >= 2 {
			sum.lon, sum.lat = sum.lon+p[0], sum.lat+p[1]
			n++
		}
	}
	if n == 0 {
		return lonLat{}, false
	}
	return lonLat{sum.lon / float64(n), sum.lat / float64(n)}, true
}

// pointGeometry is p as a GeoJSON point, which upsertPlaces turns into a circle.
func pointGeometry(p lonLat) string {
	return fmt.Sprintf(`{"type":"Point","coordinates":[%g,%g]}`, p.lon, p.lat)
}

const metresPerDegree = 111320

// distanceM is the distance between two places a few hundred metres apart, on a plane at their
// latitude.
func distanceM(a, b lonLat) float64 {
	dlon := math.Abs(a.lon - b.lon)
	if dlon > 180 {
		dlon = 360 - dlon
	}
	x := dlon * math.Cos((a.lat+b.lat)/2*math.Pi/180)
	return math.Hypot(x, a.lat-b.lat) * metresPerDegree
}

// gridDeg is the side of a viewpointGrid cell.
const gridDeg = 0.01

// viewpointGrid holds the import's viewpoints by grid cell, so near looks at a few cells
// instead of every viewpoint on the planet.
type viewpointGrid map[[2]int][]lonLat

func gridCell(p lonLat) [2]int {
	return [2]int{int(math.Floor(p.lon / gridDeg)), int(math.Floor(p.lat / gridDeg))}
}

func (g viewpointGrid) add(p lonLat) {
	c := gridCell(p)
	g[c] = append(g[c], p)
}

// near reports whether a viewpoint lies within m metres of p. A cell narrows toward the poles,
// so the cells searched east and west widen with latitude.
func (g viewpointGrid) near(p lonLat, m float64) bool {
	c := gridCell(p)
	dLat := int(math.Ceil(m / (gridDeg * metresPerDegree)))
	dLon := int(math.Ceil(m / (gridDeg * metresPerDegree * math.Max(math.Cos(p.lat*math.Pi/180), 0.01))))
	for x := c[0] - dLon; x <= c[0]+dLon; x++ {
		for y := c[1] - dLat; y <= c[1]+dLat; y++ {
			for _, v := range g[[2]int{x, y}] {
				if distanceM(p, v) <= m {
					return true
				}
			}
		}
	}
	return false
}
