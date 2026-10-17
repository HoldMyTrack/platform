package fog

import (
	"encoding/json"
	"math"
	"testing"

	"github.com/HoldMyTrack/platform/services/server/internal/mapstyle"
)

// servedLayers decodes what this package's tiles are drawn by: the coverage group of the served
// layers document (apps/web/src/map/coverageGroup.ts).
type servedLayers struct {
	Groups []struct {
		ID      string `json:"id"`
		Sources map[string]struct {
			MaxZoom int `json:"maxzoom"`
		} `json:"sources"`
		Layers []struct {
			ID    string                     `json:"id"`
			Paint map[string]json.RawMessage `json:"paint"`
		} `json:"layers"`
	} `json:"groups"`
}

// TestServedLayersMatchTheTiles holds the clients' drawing to what the tiles assume: the heat
// circles' radius, which weighNeighbours weights each point against, and the last zoom of each
// tile kind.
func TestServedLayersMatchTheTiles(t *testing.T) {
	for _, flavor := range mapstyle.Flavors() {
		doc, err := mapstyle.Layers(flavor, "abcd1234.1")
		if err != nil {
			t.Fatal(err)
		}
		var served servedLayers
		if err := json.Unmarshal(doc, &served); err != nil {
			t.Fatal(err)
		}
		found := false
		for _, o := range served.Groups {
			if o.ID != "coverage" {
				continue
			}
			found = true
			if got := o.Sources["fog-vector"].MaxZoom; got != Zoom {
				t.Errorf("%s: fog-vector maxzoom = %d, want %d", flavor, got, Zoom)
			}
			if got := o.Sources["heat-points"].MaxZoom; got != HeatPointsMaxZoom {
				t.Errorf("%s: heat-points maxzoom = %d, want %d", flavor, got, HeatPointsMaxZoom)
			}
			var radius []any
			for _, l := range o.Layers {
				if l.ID == "heat-points-circles" {
					if err := json.Unmarshal(l.Paint["heatmap-radius"], &radius); err != nil {
						t.Fatalf("%s: heatmap-radius: %v", flavor, err)
					}
				}
			}
			// ["interpolate", ["exponential", 2], ["zoom"], 0, r, …]: r px at a tile's own zoom, where
			// a 512 px tile holds heatCellsPerSide cells.
			if len(radius) < 5 {
				t.Fatalf("%s: heatmap-radius = %v", flavor, radius)
			}
			cells := radius[4].(float64) / (512.0 / heatCellsPerSide)
			if math.Abs(cells-heatRadiusCells) > 1e-9 {
				t.Errorf("%s: heat circles are %v cells across, weighNeighbours assumes %v", flavor, cells, heatRadiusCells)
			}
		}
		if !found {
			t.Errorf("%s: no coverage group", flavor)
		}
	}
}
