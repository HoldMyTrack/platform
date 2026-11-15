// Package tilemathtest finds slippy-map tiles and their bounds for tests: production code
// projects points (tilemath.WorldPixel) and never needs a tile's index or envelope.
package tilemathtest

import "math"

// LonLatToTile converts a WGS84 point to its slippy-map tile coordinate at the given zoom.
func LonLatToTile(lon, lat float64, zoom int) (x, y int) {
	n := math.Pow(2, float64(zoom))
	x = int(math.Floor((lon + 180) / 360 * n))
	latRad := lat * math.Pi / 180
	y = int(math.Floor((1 - math.Log(math.Tan(latRad)+1/math.Cos(latRad))/math.Pi) / 2 * n))
	// Clamp rather than let a pole-adjacent or antimeridian point produce an out-of-range
	// tile index — GPS noise near ±90° latitude is the realistic trigger, not a real route.
	max := int(n) - 1
	if x < 0 {
		x = 0
	} else if x > max {
		x = max
	}
	if y < 0 {
		y = 0
	} else if y > max {
		y = max
	}
	return x, y
}

// TileBounds returns a tile's WGS84 envelope (minLon, minLat, maxLon, maxLat).
func TileBounds(x, y, zoom int) (minLon, minLat, maxLon, maxLat float64) {
	n := math.Pow(2, float64(zoom))
	minLon = float64(x)/n*360 - 180
	maxLon = float64(x+1)/n*360 - 180
	maxLat = TileYToLat(float64(y), n)
	minLat = TileYToLat(float64(y+1), n)
	return
}

// TileYToLat is the latitude of tile row y, fractional, of n rows.
func TileYToLat(y, n float64) float64 {
	rad := math.Atan(math.Sinh(math.Pi * (1 - 2*y/n)))
	return rad * 180 / math.Pi
}
