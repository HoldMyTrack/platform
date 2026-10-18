package httpapi

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/HoldMyTrack/platform/services/server/internal/mapstyle"
)

// TestLayersMatchTheTileHandlers holds the layers document (apps/web/src/map/mapLayers.ts) to
// the tiles it draws: each source's first zoom to the handler's, and each source layer to a
// layer the handler's ST_AsMVT names. Fog and Heatmap are internal/fog's to check.
func TestLayersMatchTheTileHandlers(t *testing.T) {
	minZooms := map[string]int{"bike-paths": bikePathsMinZoom, "spots": spotsMinZoom}
	queries := map[string]string{"bike-paths": bikePathsQuery, "spots": spotsQuery, "tracks": tracksQuery}
	for _, flavor := range mapstyle.Flavors() {
		doc, err := mapstyle.Layers(flavor, "abcd1234.1")
		if err != nil {
			t.Fatal(err)
		}
		var served struct {
			Groups []struct {
				Sources map[string]struct {
					Tiles   string `json:"tiles"`
					MinZoom int    `json:"minzoom"`
				} `json:"sources"`
				Layers []struct {
					ID          string `json:"id"`
					Source      string `json:"source"`
					SourceLayer string `json:"source-layer"`
				} `json:"layers"`
			} `json:"groups"`
		}
		if err := json.Unmarshal(doc, &served); err != nil {
			t.Fatal(err)
		}
		checked := map[string]bool{}
		for _, g := range served.Groups {
			kinds := map[string]string{}
			for id, s := range g.Sources {
				kind, _, _ := strings.Cut(strings.TrimPrefix(s.Tiles, tilesPrefix+"/"), "/")
				kinds[id] = kind
				if want, ok := minZooms[kind]; ok {
					checked[kind] = true
					if s.MinZoom != want {
						t.Errorf("%s: %s minzoom = %d, the tiles start at %d", flavor, id, s.MinZoom, want)
					}
				}
			}
			for _, l := range g.Layers {
				query, ok := queries[kinds[l.Source]]
				if !ok || l.SourceLayer == "" {
					continue
				}
				if !strings.Contains(query, "ST_AsMVT(t, '"+l.SourceLayer+"'") {
					t.Errorf("%s: %s reads source layer %q, which the %s tiles don't have", flavor, l.ID, l.SourceLayer, kinds[l.Source])
				}
			}
		}
		for kind := range minZooms {
			if !checked[kind] {
				t.Errorf("%s: no %s source", flavor, kind)
			}
		}
	}
}
