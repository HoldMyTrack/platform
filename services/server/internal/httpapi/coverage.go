package httpapi

import (
	"net/http"

	"github.com/HoldMyTrack/platform/services/server/internal/fog"
)

// coverageRenderingQuery reports whether any job that changes this account's Fog/Heatmap
// rasters is still unfinished. A claimed job keeps state = 'pending' until the worker marks it
// done or failed (internal/worker's claimAndRunOne only sets locked_at), so this covers
// running jobs too. `ingest`, `edit_track`, `reprivacy` and `story_copy` are included, not just
// `render_fog`: an upload the client has already seen accepted may not have been parsed yet, and
// until it has, the `render_fog` job it will enqueue doesn't exist to be waited on; an accepted
// copy of a Story is the same, one activity at a time. A job waiting out a retry's delay
// (internal/worker's retryDelays, or a `reprivacy` rerun) is left out: nothing renders until it
// runs, and a reprivacy rerun's activities stay off the map meanwhile.
//
// The second column is the version: the account's map_version, bumped at the end of every
// render pass and by every request-time change to what a tile returns (fog.BumpMapVersion). A
// job can render more than once before it finishes — a track edit or Private location change
// renders once with its activities left out (Pending) and again once they're back — so a
// client that should show the in-between state refetches whenever this changes, not only once
// rendering is over.
const coverageRenderingQuery = `
SELECT EXISTS (
    SELECT 1 FROM jobs
    WHERE user_id = $1 AND state = 'pending' AND kind IN ('ingest', 'edit_track', 'reprivacy', 'render_fog', 'story_copy')
      AND NOT (run_after > NOW() AND (attempts > 0 OR kind = 'reprivacy'))
),
(SELECT map_version FROM users WHERE id = $1)`

// exploredQuery counts the places of each level the account has been in, as the map clears them
// (visitedCTEs): derived from the matches on every request, so a deletion, a track edit or a
// Private location can't leave a stored count behind. Stand-ins aside.
var exploredQuery = `
WITH ` + visitedCTEs("$1") + `
SELECT (SELECT count(*) FROM v_country),
       (SELECT count(*) FROM v_region v JOIN admin_regions x ON x.id = v.id WHERE x.overture_id NOT LIKE 'country:%'),
       (SELECT count(*) FROM v_county v JOIN admin_counties x ON x.id = v.id WHERE x.kind = 'county'),
       (SELECT count(*) FROM v_city v JOIN admin_cities x ON x.id = v.id WHERE x.kind = 'city')`

type coverageStatusResponse struct {
	Rendering bool  `json:"rendering"`
	Version   int64 `json:"version"`
	// TileVersion is what a client sends as every tile request's `cv` to have the tile cached
	// (setTileCacheControl) — Version plus the account it belongs to (fog.TileVersion).
	TileVersion string `json:"tile_version"`
	// Explored counts the places of each level Fog clears for the account (SPEC.md FR-4.2).
	Explored explored `json:"explored"`
}

type explored struct {
	Countries int `json:"countries"`
	Regions   int `json:"regions"`
	Counties  int `json:"counties"`
	Cities    int `json:"cities"`
}

// handleCoverageStatus serves `GET /v1/coverage/status` (IMPLEMENTATION.md §4.2.3): the
// signal a client polls after an upload or delete to know when refetching Fog/Heatmap tiles
// will return the new coverage rather than the old. The tile URLs themselves are fixed and
// the rasters are rendered asynchronously, so without this the client has no way to tell.
func (s *Server) handleCoverageStatus(w http.ResponseWriter, r *http.Request) {
	var resp coverageStatusResponse
	userID := userIDFromContext(r.Context())
	if err := s.pool.QueryRow(r.Context(), coverageRenderingQuery, userID).Scan(&resp.Rendering, &resp.Version); err != nil {
		if clientGone(w, r) {
			return
		}
		s.log.Error("coverage status query failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	resp.TileVersion = fog.TileVersion(userID, resp.Version)
	e := &resp.Explored
	if err := s.pool.QueryRow(r.Context(), exploredQuery, userID).Scan(&e.Countries, &e.Regions, &e.Counties, &e.Cities); err != nil {
		if clientGone(w, r) {
			return
		}
		s.log.Error("coverage status: explored", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, resp)
}
