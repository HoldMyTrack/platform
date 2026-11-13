package fog

import (
	"encoding/json"
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
	} `json:"groups"`
}

// TestServedLayersMatchTheTiles holds the clients' drawing to what the tiles assume: the last
// zoom Fog's tiles are made for.
func TestServedLayersMatchTheTiles(t *testing.T) {
	for _, flavor := range mapstyle.Flavors() {
		doc, err := mapstyle.Layers(flavor, "abcd1234.1", "en", mapstyle.Words{})
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
		}
		if !found {
			t.Errorf("%s: no coverage group", flavor)
		}
	}
}
