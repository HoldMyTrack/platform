package httpapi

import (
	"context"
	"net/http"
	"sync"
	"time"

	"github.com/HoldMyTrack/platform/services/server/internal/imagery"
	"github.com/HoldMyTrack/platform/services/server/internal/mapstyle"
)

// imageryCacheTTL is how long a read of imagery_status answers for: the worker decides at most
// every 30 minutes (internal/imagery), and the style is fetched on every map load.
const imageryCacheTTL = time.Minute

// imageryCache is the last imagery_status read, shared by every request.
type imageryCache struct {
	mu        sync.Mutex
	available bool
	at        time.Time
}

// imageryOffered is whether the deployment configures imagery and the worker hasn't paused it
// (docs/SPEC.md FR-4.14, docs/IMPLEMENTATION.md §4.26).
func imageryOffered(configured bool, stored imagery.Status, found bool) bool {
	return configured && (!found || stored.Available)
}

// imageryAvailable is imageryOffered for this deployment, read at most once per imageryCacheTTL.
// A read that fails keeps the last answer, or offers imagery when there is none: the clients'
// own fallback covers imagery that then fails to load.
func (s *Server) imageryAvailable(ctx context.Context) bool {
	if s.satellite.Tiles == "" {
		return false
	}
	// A server without a database (the pages' tests) has nothing decided, like an empty table.
	if s.pool == nil {
		return true
	}
	c := &s.imagery
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.at.IsZero() && time.Since(c.at) < imageryCacheTTL {
		return c.available
	}
	stored, found, err := imagery.Load(ctx, s.pool)
	if err != nil {
		s.log.Error("imagery status read", "err", err)
		if c.at.IsZero() {
			return true
		}
		return c.available
	}
	c.available, c.at = imageryOffered(true, stored, found), time.Now()
	return c.available
}

// styleSatellite is the imagery the served style carries: none while paused, so a native client
// shows no Satellite switch, as on a deployment without imagery.
func (s *Server) styleSatellite(ctx context.Context) mapstyle.Satellite {
	if !s.imageryAvailable(ctx) {
		return mapstyle.Satellite{}
	}
	return s.satellite
}

type imageryResponse struct {
	Available bool `json:"available"`
}

// handleMapImagery serves `GET /v1/map/imagery`: whether Satellite is offered now. The web reads
// its imagery from its build, so it asks this at load and every few minutes; native clients read
// the same answer from the served style.
func (s *Server) handleMapImagery(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, imageryResponse{Available: s.imageryAvailable(r.Context())})
}
