package httpapi

import "net/http"

// The Region, County and City levels' handlers mirror admin_country_tiles.go's Country one, a
// level down each: see that file for the query and the cache they share.

func (s *Server) handleRegionFogTile(w http.ResponseWriter, r *http.Request) {
	s.serveAdminTile(w, r, regionLayer, regionFogQueries)
}

func (s *Server) handleCountyFogTile(w http.ResponseWriter, r *http.Request) {
	s.serveAdminTile(w, r, countyLayer, countyFogQueries)
}

func (s *Server) handleCityFogTile(w http.ResponseWriter, r *http.Request) {
	s.serveAdminTile(w, r, cityLayer, cityFogQueries)
}
