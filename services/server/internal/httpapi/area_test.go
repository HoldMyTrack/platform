package httpapi

import (
	"reflect"
	"testing"
)

func TestParseBBox(t *testing.T) {
	area := func(w, e []float64) mapArea { return mapArea{south: -10, north: 10, west: w, east: e} }
	for raw, want := range map[string]mapArea{
		"10,-10,20,10":     area([]float64{10}, []float64{20}),
		"170,-10,190,10":   area([]float64{170, -180}, []float64{180, -170}),
		"170,-10,-170,10":  area([]float64{170, -180}, []float64{180, -170}),
		"-190,-10,-170,10": area([]float64{170, -180}, []float64{180, -170}),
		"530,-10,540,10":   area([]float64{170}, []float64{180}),
		"-200,-10,200,10":  area([]float64{-180}, []float64{180}),
		"-180,-10,180,10":  area([]float64{-180}, []float64{180}),
		"10,-100,20,100":   {south: -90, north: 90, west: []float64{10}, east: []float64{20}},
	} {
		if got, ok := parseBBox(raw); !ok || !reflect.DeepEqual(got, want) {
			t.Errorf("parseBBox(%q) = %+v, %v, want %+v", raw, got, ok, want)
		}
	}
	for _, raw := range []string{"10,10,20,-10", "10,-10,10,10", "1,2,3", "a,b,c,d", "NaN,0,1,1"} {
		if _, ok := parseBBox(raw); ok {
			t.Errorf("parseBBox(%q) accepted", raw)
		}
	}
}
