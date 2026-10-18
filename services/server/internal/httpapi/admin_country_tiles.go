package httpapi

import (
	"context"
	"fmt"
	"net/http"
)

// adminLayer is one of the two outline sets the Country and Region tiers draw
// (docs/IMPLEMENTATION.md §4.2.4): which table holds the outlines, which holds each
// activity's matches to them (populated once at ingest by internal/geo.MatchActivity, never at
// request time), the tile's MVT layer name, and the key of its rows in admin_tile_geoms.
type adminLayer struct {
	name     string
	cache    string
	outlines string
	matches  string
	matchID  string
	// cacheMaxZoom is the highest zoom whose tiles are kept in admin_tile_geoms: the source's
	// maxzoom in the served layers document (apps/web/src/map/coverageGroup.ts). A tile past it, which no client
	// asks for, is drawn live rather than letting anyone fill the table with tiles nothing
	// draws.
	cacheMaxZoom int
}

var (
	countryLayer = adminLayer{name: "countries", cache: "country-veil", outlines: "admin_countries", matches: "activity_country", matchID: "country_id", cacheMaxZoom: 3}
	regionLayer  = adminLayer{name: "regions", cache: "region-veil", outlines: "admin_regions", matches: "activity_region", matchID: "region_id", cacheMaxZoom: 7}
)

// seaID is the admin_id of a tile's sea: the tile's frame with every outline in it cut out.
// Outline ids start at 1.
const seaID = 0

// liveGeoms draws every outline in tile ($1, $2, $3), transformed and clipped to it, and the
// tile's sea, so the veil covers the water too. The same for every account, so serveAdminTile
// keeps it in admin_tile_geoms rather than drawing it on every request: transforming and
// clipping is most of a tile's cost (docs/PERFORMANCE.md, 2026-10-09 dev, over 80 ms for the
// world's z0 Country tile), and the sea's union over a second for it.
//
// The frame reaches just past the tile, as fog.veilPolygons' does, so no edge falls on the tile's
// border, where antialiasing drew a seam. At the world's top and bottom it stops at the edge: the
// globe draws what lies past it over the pole, once per tile in the row. GEOS winds a
// difference's outer ring the other way from ST_AsMVTGeom, and a vector tile reads that as a hole.
func (l adminLayer) liveGeoms() string {
	return fmt.Sprintf(`
		WITH outlines AS (
			SELECT o.id AS admin_id,
			       ST_AsMVTGeom(ST_Transform(o.geom, 3857), ST_TileEnvelope($1, $2, $3), 4096, 64, true) AS geom
			FROM %s o
			WHERE o.geom && ST_Transform(ST_TileEnvelope($1, $2, $3), 4326)
		), frame AS (
			SELECT ST_MakeEnvelope(
				-2, CASE WHEN $3 = 0 THEN 0 ELSE -2 END,
				4098, CASE WHEN $3 = power(2, $1)::int - 1 THEN 4096 ELSE 4098 END, 3857) AS geom
		), sea AS (
			SELECT ST_ForcePolygonCCW(COALESCE(ST_Difference(f.geom, ST_Union(o.geom)), f.geom)) AS geom
			FROM frame f LEFT JOIN outlines o ON true
			GROUP BY f.geom
		)
		SELECT admin_id, geom FROM outlines
		UNION ALL
		SELECT %d, geom FROM sea WHERE NOT ST_IsEmpty(geom)`, l.outlines, seaID)
}

// tileQuery is one account's tile ($1, $2, $3) of this layer, for account $4: the sea and the
// outlines the account has no activity in (the locked side), which Fog veils.
//
// visited starts from the account's own activities, so its cost is the account's history,
// not every account's matches in the outlines the tile covers. It answers two columns: whether
// the tile is in admin_tile_geoms yet (always true for a live one) and the tile itself, its
// features in outline order whichever way it was drawn.
func (l adminLayer) tileQuery(cached bool) string {
	built, geoms := "true", l.liveGeoms()
	if cached {
		built = fmt.Sprintf(`EXISTS (
			SELECT 1 FROM admin_tiles_built
			WHERE layer = '%s' AND zoom = $1 AND tile_x = $2 AND tile_y = $3)`, l.cache)
		geoms = fmt.Sprintf(`
			SELECT admin_id, geom FROM admin_tile_geoms
			WHERE layer = '%s' AND zoom = $1 AND tile_x = $2 AND tile_y = $3`, l.cache)
	}
	return fmt.Sprintf(`
		WITH visited AS MATERIALIZED (
			SELECT DISTINCT m.%[1]s AS id
			FROM activities a JOIN %[2]s m ON m.activity_id = a.id
			WHERE a.user_id = $4 AND NOT a.edit_pending
		)
		SELECT %[3]s,
		       (SELECT ST_AsMVT(t, '%[4]s', 4096, 'geom')
		        FROM (
		            SELECT g.admin_id AS id, g.geom
		            FROM (%[5]s) g
		            WHERE NOT EXISTS (SELECT 1 FROM visited v WHERE v.id = g.admin_id)
		            ORDER BY g.admin_id
		        ) t)`, l.matchID, l.matches, built, l.name, geoms)
}

// adminTileQueries are the two handlers' queries, cached and live, built once.
type adminTileQueries struct{ cached, live string }

var (
	countryFogQueries = adminTileQueries{countryLayer.tileQuery(true), countryLayer.tileQuery(false)}
	regionFogQueries  = adminTileQueries{regionLayer.tileQuery(true), regionLayer.tileQuery(false)}
)

func (s *Server) handleCountryFogTile(w http.ResponseWriter, r *http.Request) {
	s.serveAdminTile(w, r, countryLayer, countryFogQueries)
}

// serveAdminTile is shared by the Country and Region tile handlers (this file's and
// admin_region_tiles.go's) — they differ only in the layer and its queries, not in how tile
// coordinates are parsed or the result written. A tile up to the layer's cacheMaxZoom is read
// from admin_tile_geoms, built there by its first request (buildAdminTile).
//
// Registered without ".mvt" in the route pattern, same as handleTracksTile — net/http's
// ServeMux wildcard has to occupy a whole path segment, so the suffix is trimmed by hand here
// too.
func (s *Server) serveAdminTile(w http.ResponseWriter, r *http.Request, l adminLayer, q adminTileQueries) {
	z, x, y, ok := tileCoords(w, r, ".mvt")
	if !ok {
		return
	}
	ctx := r.Context()
	query := q.live
	if z <= l.cacheMaxZoom {
		query = q.cached
	}

	var built bool
	var tile []byte
	err := s.pool.QueryRow(ctx, query, z, x, y, userIDFromContext(ctx)).Scan(&built, &tile)
	if err == nil && !built {
		if err = s.buildAdminTile(ctx, l, z, x, y); err == nil {
			err = s.pool.QueryRow(ctx, query, z, x, y, userIDFromContext(ctx)).Scan(&built, &tile)
		}
	}
	if err != nil {
		if clientGone(w, r) {
			return
		}
		s.log.Error("admin tile query failed", "err", err, "layer", l.name, "z", z, "x", x, "y", y)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/vnd.mapbox-vector-tile")
	setTileCacheControl(w, r)
	_, _ = w.Write(tile)
}

// buildAdminTile stores one tile's outlines in admin_tile_geoms and marks it built, in one
// transaction. The mark goes first: a second request building the same tile at once waits on
// it, then finds it taken and leaves the tile to the first. The outlines are read by a
// statement after the mark, so a build that waited on seed-admin-boundaries' TRUNCATE draws
// the new outlines, not the ones it replaced.
func (s *Server) buildAdminTile(ctx context.Context, l adminLayer, z, x, y int) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck // no-op if already committed
	tag, err := tx.Exec(ctx, `
		INSERT INTO admin_tiles_built (layer, zoom, tile_x, tile_y) VALUES ($1, $2, $3, $4)
		ON CONFLICT DO NOTHING`, l.cache, z, x, y)
	if err != nil {
		return fmt.Errorf("mark admin tile built: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return nil
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO admin_tile_geoms (layer, zoom, tile_x, tile_y, admin_id, geom)
		SELECT $4, $1, $2, $3, g.admin_id, g.geom
		FROM (`+l.liveGeoms()+`) g
		WHERE g.geom IS NOT NULL`, z, x, y, l.cache); err != nil {
		return fmt.Errorf("build admin tile: %w", err)
	}
	return tx.Commit(ctx)
}
