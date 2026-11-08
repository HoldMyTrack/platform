package httpapi

import (
	"context"
	"image"
	"net/http"

	"github.com/HoldMyTrack/platform/services/server/internal/fog"
	"github.com/HoldMyTrack/platform/services/server/internal/parallel"
)

// handleFogVectorTile serves Fog as vector shapes (IMPLEMENTATION.md §4.2): the veil and its
// edges, traced from the stored coverage tile — read, decoded and traced per request, so the
// render and what it stores don't change. The clients draw the veil as a fill and its edges as a
// blurred line, crisp at every zoom. The tile's four neighbours are read with it, so an outline
// crossing a side meets theirs exactly (fog.Sides).
func (s *Server) handleFogVectorTile(w http.ResponseWriter, r *http.Request) {
	z, x, y, ok := tileCoords(w, r, ".mvt")
	if !ok {
		return
	}
	ctx := r.Context()
	n := 1 << z
	// The tile, then its left, right, top and bottom neighbours, x wrapping round the world; past
	// the world's top or bottom there is none.
	at := [5][2]int{{x, y}, {(x - 1 + n) % n, y}, {(x + 1) % n, y}, {x, y - 1}, {x, y + 1}}
	keys, err := s.fogTileKeys(ctx, z, at)
	if err != nil {
		s.fogVectorFailed(w, r, "row", err, z, x, y)
		return
	}
	stored, err := loadMaskPNG(ctx, s.store, keys[0])
	if err != nil {
		s.fogVectorFailed(w, r, "fetch", err, z, x, y)
		return
	}
	cov, err := fog.DecodeCoverage(stored)
	if err != nil {
		s.fogVectorFailed(w, r, "decode", err, z, x, y)
		return
	}
	sides := s.fogSides(ctx, keys, at, n)
	w.Header().Set("Content-Type", "application/vnd.mapbox-vector-tile")
	setTileCacheControl(w, r)
	_, _ = w.Write(fog.EncodeFogTile(cov, sides, z < fog.Zoom)) // fails only when the client has gone
}

// fogTileKeys reads the stored object of each of at's tiles in one query: nil where nothing is on
// file.
func (s *Server) fogTileKeys(ctx context.Context, z int, at [5][2]int) ([5]*string, error) {
	var keys [5]*string
	xs, ys := make([]int32, len(at)), make([]int32, len(at))
	for i, t := range at {
		xs[i], ys[i] = int32(t[0]), int32(t[1])
	}
	rows, err := s.pool.Query(ctx, `
		SELECT tile_x, tile_y, object_key FROM fog_tiles
		WHERE user_id = $1 AND zoom = $2 AND (tile_x, tile_y) IN (SELECT * FROM unnest($3::int[], $4::int[]))`,
		userIDFromContext(ctx), z, xs, ys)
	if err != nil {
		return keys, err
	}
	defer rows.Close()
	for rows.Next() {
		var tx, ty int
		var key *string
		if err := rows.Scan(&tx, &ty, &key); err != nil {
			return keys, err
		}
		for i, t := range at {
			if t == [2]int{tx, ty} {
				keys[i] = key
			}
		}
	}
	return keys, rows.Err()
}

// fogSides reads the four neighbours' coverage side by side. One past the world's edge, or one
// that can't be read, is left unknown, and the tracer carries the tile's own pixels on past that
// side instead: a kink at street zoom, never a failed tile.
func (s *Server) fogSides(ctx context.Context, keys [5]*string, at [5][2]int, n int) fog.Sides {
	var got [4]*image.Gray
	_ = parallel.ForEach(ctx, 4, 4, func(ctx context.Context, i int) error {
		if t := at[i+1]; t[1] < 0 || t[1] >= n {
			return nil
		}
		stored, err := loadMaskPNG(ctx, s.store, keys[i+1])
		if err != nil {
			return nil
		}
		if cov, err := fog.DecodeCoverage(stored); err == nil {
			got[i] = cov
		}
		return nil
	})
	return fog.Sides{Left: got[0], Right: got[1], Top: got[2], Bottom: got[3]}
}

func (s *Server) fogVectorFailed(w http.ResponseWriter, r *http.Request, step string, err error, z, x, y int) {
	if clientGone(w, r) {
		return
	}
	s.log.Error("fog vector tile failed", "step", step, "err", err, "z", z)
	writeAPIError(w, "internal error", http.StatusInternalServerError)
}
