package spots

import (
	"math"
	"testing"
)

func TestAnchor(t *testing.T) {
	cases := []struct {
		geometry string
		want     lonLat
		ok       bool
	}{
		{`{"type":"Point","coordinates":[-81.5,41.2]}`, lonLat{-81.5, 41.2}, true},
		// The first outer ring's vertices, averaged; holes and later polygons don't count.
		{`{"type":"Polygon","coordinates":[[[0,0],[2,0],[2,2],[0,2]],[[1,1],[1,1.5],[1.5,1.5]]]}`, lonLat{1, 1}, true},
		{`{"type":"MultiPolygon","coordinates":[[[[0,0],[4,0],[4,4],[0,4]]],[[[10,10],[11,10],[11,11]]]]}`, lonLat{2, 2}, true},
		{`{"type":"LineString","coordinates":[[0,0],[1,1]]}`, lonLat{}, false},
		{`{"type":"Polygon","coordinates":[]}`, lonLat{}, false},
		{`null`, lonLat{}, false},
	}
	for _, c := range cases {
		got, ok := anchor(c.geometry)
		if ok != c.ok || got != c.want {
			t.Errorf("anchor(%s) = %v, %v; want %v, %v", c.geometry, got, ok, c.want, c.ok)
		}
	}
}

func TestDistanceM(t *testing.T) {
	cases := []struct {
		a, b lonLat
		want float64
	}{
		{lonLat{0, 0}, lonLat{0, 0.001}, 111.32},
		{lonLat{0, 60}, lonLat{0.002, 60}, 111.32},
		// Across the antimeridian.
		{lonLat{179.9995, 0}, lonLat{-179.9995, 0}, 111.32},
	}
	for _, c := range cases {
		if got := distanceM(c.a, c.b); math.Abs(got-c.want) > 0.5 {
			t.Errorf("distanceM(%v, %v) = %.2f, want %.2f", c.a, c.b, got, c.want)
		}
	}
}

func TestViewpointGridNear(t *testing.T) {
	g := viewpointGrid{}
	// One mid-latitude viewpoint, and one far north, where a grid cell is narrower than the radius.
	g.add(lonLat{-81.5, 41.2})
	g.add(lonLat{20.0, 80.0})
	const deg = 1 / float64(metresPerDegree)
	east := func(m float64) float64 { return m * deg / math.Cos(80*math.Pi/180) }
	cases := []struct {
		at   lonLat
		want bool
	}{
		{lonLat{-81.5, 41.2 - 119*deg}, true},
		{lonLat{-81.5, 41.2 - 121*deg}, false},
		{lonLat{20.0 + east(119), 80.0}, true},
		{lonLat{20.0 + east(121), 80.0}, false},
		{lonLat{0, 0}, false},
	}
	for _, c := range cases {
		if got := g.near(c.at, viewpointNearM); got != c.want {
			t.Errorf("near(%v) = %v, want %v", c.at, got, c.want)
		}
	}
}

func TestRadiusM(t *testing.T) {
	if radiusM("waterfall") != 75 || radiusM("viewpoint") != 30 {
		t.Errorf("radii: waterfall %v, viewpoint %v; want 75 and 30", radiusM("waterfall"), radiusM("viewpoint"))
	}
}
