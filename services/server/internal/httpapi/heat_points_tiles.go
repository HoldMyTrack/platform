package httpapi

import "net/http"

// handleHeatPointsTile answers every heat-points tile with an empty vector tile and reads
// nothing. It serves installed Android builds that still ask for Heatmap's tiles, until
// MIN_ANDROID_BUILD next goes up.
func (s *Server) handleHeatPointsTile(w http.ResponseWriter, r *http.Request) {
	if _, _, _, ok := tileCoords(w, r, ".mvt"); !ok {
		return
	}
	w.Header().Set("Content-Type", "application/vnd.mapbox-vector-tile")
	setTileCacheControl(w, r)
}
