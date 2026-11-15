package httpapi

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// Show in this area takes a view up to 10° each way, across the antimeridian too, and refuses
// a larger one before counting any place.
func TestSpotsAreaRefusesAWideView(t *testing.T) {
	s := &Server{}
	for _, bbox := range []string{"0,40,20,45", "0,30,5,45", "170,40,185,45", "175,40,-170,45"} {
		rec := httptest.NewRecorder()
		s.handleSpotsInArea(rec, httptest.NewRequest(http.MethodGet, "/v1/spots?categories=playground&bbox="+bbox, nil))
		if rec.Code != http.StatusBadRequest {
			t.Errorf("bbox %s: %d, want 400", bbox, rec.Code)
		}
	}
	for bbox, want := range map[string][2]float64{"10,40,15,45": {5, 5}, "175,40,-175,45": {10, 5}} {
		a, ok := parseBBox(bbox)
		if lon, lat := a.span(); !ok || lon != want[0] || lat != want[1] {
			t.Errorf("span of %s: %v° by %v°, want %v", bbox, lon, lat, want)
		}
	}
}
