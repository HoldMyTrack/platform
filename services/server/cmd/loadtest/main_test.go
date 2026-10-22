package main

import (
	"math"
	"testing"
)

func TestWindowBBox(t *testing.T) {
	near := func(a, b float64) bool { return math.Abs(a-b) < 1e-6 }
	// At zoom 10 a 1280 px window spans 2.5 tiles of 360/1024 degrees.
	b := windowBBox(pt{lat: 0, lon: 0}, 10)
	if w := 2.5 * 360 / 1024; !near(b[2]-b[0], w) || !near(b[0], -w/2) {
		t.Errorf("west/east %v, %v: want a %v° span centred on 0", b[0], b[2], w)
	}
	if !near(b[1], -b[3]) || b[3] <= 0 {
		t.Errorf("south/north %v, %v: want symmetric about the equator", b[1], b[3])
	}
	// Across the antimeridian east runs past 180, as parseBBox accepts.
	if b := windowBBox(pt{lat: 50, lon: 179.9}, 10); b[2] <= 180 || b[0] >= 180 {
		t.Errorf("antimeridian box %v: want west below and east above 180", b)
	}
	// North of the window stays below the pole at the map's edge.
	if b := windowBBox(pt{lat: 85, lon: 0}, 10); b[3] > 85.06 || b[1] >= b[3] {
		t.Errorf("polar box %v", b)
	}
}

func TestAsksArea(t *testing.T) {
	for _, c := range []struct {
		spots bool
		z     int
		roll  int
		want  bool
	}{
		{true, 10, 0, true},
		{true, 12, 0, true},
		{true, 9, 0, false},  // below the request zoom
		{true, 13, 0, false}, // the spots tiles draw places from here
		{true, 11, 1, false},
		{false, 11, 0, false},
	} {
		if got := asksArea(c.spots, c.z, c.roll); got != c.want {
			t.Errorf("asksArea(%v, %d, %d) = %v", c.spots, c.z, c.roll, got)
		}
	}
}
