package ingest

import (
	"math"
	"testing"
)

// Exactly antipodal points are half the Earth's circumference apart, never NaN: rounding can
// push the haversine term just past 1 for them.
func TestHaversineMAntipodes(t *testing.T) {
	half := math.Pi * earthRadiusM
	for lat := -89.0; lat <= 89; lat += 0.01 {
		d := HaversineM(lat, 10, -lat, -170)
		if math.IsNaN(d) || math.Abs(d-half) > 1 {
			t.Fatalf("lat %v: %v m, want %v", lat, d, half)
		}
	}
}
