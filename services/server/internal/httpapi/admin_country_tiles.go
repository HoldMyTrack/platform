package httpapi

import (
	"context"
	"fmt"
	"net/http"

	"github.com/HoldMyTrack/platform/services/server/internal/i18n"
)

// adminLayer is one of the outline sets Fog's levels draw (docs/IMPLEMENTATION.md §4.2.4):
// which table holds the outlines, the tile's MVT layer name and the key of its rows in
// admin_tile_geoms, and the SQL for what each outline's feature says.
type adminLayer struct {
	name     string
	cache    string
	outlines string
	// visited names the visitedCTEs set of this level's places the account has been in.
	visited string
	// kind, localType and within are the SQL for what the tooltip says over the outlines table
	// as o, with names in language $5: what the place is (on the County and City levels a stand-in
	// is the region or county it comes from), its kind in its own country's words, and the
	// places it lies in.
	kind, localType, within string
	// counts is the SQL for the columns the tooltip counts with, over o: of each level below, the
	// places in it the account has been in and how many there are, and the words its country
	// calls them by. A stand-in counts nothing, nor does a city, with nothing below it.
	counts string
	// mergeBelow is the zoom below which a tile keeps only the places the account has been in,
	// the rest joining the sea as one veil (mergedGeoms); 0 for a level that never merges.
	mergeBelow int
	// cacheMaxZoom is the highest zoom whose tiles are kept in admin_tile_geoms: the source's
	// maxzoom in the served layers document (apps/web/src/map/coverageGroup.ts). A tile past it, which no client
	// asks for, is drawn live rather than letting anyone fill the table with tiles nothing
	// draws.
	cacheMaxZoom int
}

// visitedCTEs are the places of every level the account `user` (a parameter, $4 in a tile) has
// been in, from its activities that aren't Pending: each level's own matches (internal/geo.MatchActivity, at ingest, never at
// request time), and the places above those visited on a level below, through the parent ids,
// so a cleared city never sits in a fogged county and the counts agree with the map.
func visitedCTEs(user string) string {
	return `
	mine AS MATERIALIZED (
		SELECT id FROM activities WHERE user_id = ` + user + ` AND NOT edit_pending
	), v_city AS MATERIALIZED (
		SELECT DISTINCT m.city_id AS id FROM mine a JOIN activity_city m ON m.activity_id = a.id
	), v_county AS MATERIALIZED (
		SELECT m.county_id AS id FROM mine a JOIN activity_county m ON m.activity_id = a.id
		UNION SELECT c.county_id FROM v_city v JOIN admin_cities c ON c.id = v.id WHERE c.county_id IS NOT NULL
	), v_region AS MATERIALIZED (
		SELECT m.region_id AS id FROM mine a JOIN activity_region m ON m.activity_id = a.id
		UNION SELECT k.region_id FROM v_county v JOIN admin_counties k ON k.id = v.id WHERE k.region_id IS NOT NULL
		UNION SELECT c.region_id FROM v_city v JOIN admin_cities c ON c.id = v.id WHERE c.region_id IS NOT NULL
	), v_country AS MATERIALIZED (
		SELECT m.country_id AS id FROM mine a JOIN activity_country m ON m.activity_id = a.id
		UNION SELECT r.country_id FROM v_region v JOIN admin_regions r ON r.id = v.id
		UNION SELECT k.country_id FROM v_county v JOIN admin_counties k ON k.id = v.id
		UNION SELECT c.country_id FROM v_city v JOIN admin_cities c ON c.id = v.id
	)`
}

// nameIn is the SQL for the name of the row of table whose id is idCol, in language $5, or NULL.
func nameIn(table, idCol, cond string) string {
	return fmt.Sprintf(`(SELECT COALESCE(x.names ->> $5::text, x.name) FROM %s x WHERE x.id = %s%s)`, table, idCol, cond)
}

// count is the SQL for the columns `name` and `name_total`: how many of the places in o of a level
// below (`table`, its own places by `own`, under o by `parent`) are in `visited`, and how many
// there are (`total`), when o is its level's own place (`when`) with any.
func count(name, when, visited, table, own, parent, total string) string {
	return fmt.Sprintf(`CASE WHEN %[2]s AND %[7]s > 0 THEN (SELECT count(*) FROM %[3]s v JOIN %[4]s x ON x.id = v.id
			WHERE x.%[6]s = o.id AND %[5]s) END AS %[1]s,
		CASE WHEN %[2]s AND %[7]s > 0 THEN %[7]s END AS %[1]s_total`, name, when, visited, table, own, parent, total)
}

// countryWord is the SQL for what o's country calls its places of a level, from its `col`.
func countryWord(col string) string {
	return `(SELECT NULLIF(x.` + col + `, '') FROM admin_countries x WHERE x.id = o.country_id)`
}

var (
	// A region standing in for a country without regions is named for the country; the chain
	// skips it.
	realRegion = ` AND x.overture_id NOT LIKE 'country:%'`
	ownRegion  = `x.overture_id NOT LIKE 'country:%'`

	countryLayer = adminLayer{
		name: "countries", cache: "countries", outlines: "admin_countries", cacheMaxZoom: outlineMaxZoom,
		visited: "v_country", kind: `'country'`, localType: `NULL`, within: `NULL`,
		counts: count("regions", "true", "v_region", "admin_regions", ownRegion, "country_id", "o.regions_total") + `,
			` + count("counties", "true", "v_county", "admin_counties", "x.kind = 'county'", "country_id", "o.counties_total") + `,
			` + count("cities", "true", "v_city", "admin_cities", "x.kind = 'city'", "country_id", "o.cities_total") + `,
			NULLIF(o.region_word, '') AS region_word, NULLIF(o.county_word, '') AS county_word`,
	}
	regionLayer = adminLayer{
		name: "regions", cache: "regions", outlines: "admin_regions", cacheMaxZoom: outlineMaxZoom,
		visited:   "v_region",
		kind:      `CASE WHEN o.overture_id LIKE 'country:%' THEN 'country' ELSE 'region' END`,
		localType: `o.local_type`,
		within:    `CASE WHEN o.overture_id NOT LIKE 'country:%' THEN ` + nameIn("admin_countries", "o.country_id", "") + ` END`,
		counts: count("counties", "true", "v_county", "admin_counties", "x.kind = 'county'", "region_id", "o.counties_total") + `,
			` + count("cities", "true", "v_city", "admin_cities", "x.kind = 'city'", "region_id", "o.cities_total") + `,
			` + countryWord("county_word") + ` AS county_word`,
	}
	countyLayer = adminLayer{
		name: "counties", cache: "counties", outlines: "admin_counties", cacheMaxZoom: outlineMaxZoom, mergeBelow: countyMergeBelow,
		visited: "v_county", kind: `o.kind`, localType: `o.local_type`,
		within: `CASE o.kind
			WHEN 'county' THEN COALESCE(` + nameIn("admin_regions", "o.region_id", realRegion) + `, ` + nameIn("admin_countries", "o.country_id", "") + `)
			WHEN 'region' THEN ` + nameIn("admin_countries", "o.country_id", "") + ` END`,
		counts: count("cities", "o.kind = 'county'", "v_city", "admin_cities", "x.kind = 'city'", "county_id", "o.cities_total"),
	}
	cityLayer = adminLayer{
		name: "cities", cache: "cities", outlines: "admin_cities", cacheMaxZoom: outlineMaxZoom, mergeBelow: cityMergeBelow,
		visited: "v_city", kind: `o.kind`, localType: `o.local_type`,
		within: `CASE o.kind
			WHEN 'city' THEN NULLIF(concat_ws(', ', ` + nameIn("admin_counties", "o.county_id", ` AND x.kind = 'county'`) + `,
				COALESCE(` + nameIn("admin_regions", "o.region_id", realRegion) + `, ` + nameIn("admin_countries", "o.country_id", "") + `)), '')
			WHEN 'county' THEN COALESCE(` + nameIn("admin_regions", "o.region_id", realRegion) + `, ` + nameIn("admin_countries", "o.country_id", "") + `)
			WHEN 'region' THEN ` + nameIn("admin_countries", "o.country_id", "") + ` END`,
	}
)

// farMaxZoom is the last zoom a tile draws the outlines' far form (internal/geo's farTolerance,
// 1 km, under a pixel to here) rather than their near one.
const farMaxZoom = 6

// pixel is a screen pixel in tile units, a 4096-unit tile drawn 512 pixels wide: what a tile's
// outlines are simplified to, as one coverage, so no seam opens at any tolerance.
const pixel = 4096 / 512

// minOutlineAtZ0 is the narrowest outline a tile keeps at zoom 0, in Web Mercator metres: 4
// screen pixels, a 512-pixel tile spanning the world, halving at every zoom in. A narrower one
// drops out of the tile and its land joins the sea, so a place too small to tell apart is veiled
// until zoomed in, as a lone track is: with every outline the world's z0 City tile carried
// 983 KB for the US's towns alone, and at one pixel z4 still took 3 s to build.
const minOutlineAtZ0 = 4 * 40075016.68557849 / 512

// outlineMaxZoom is the last zoom every level's tiles are made for and kept to: a locked level
// draws at any zoom, MapLibre enlarging z10's past it, where a tile unit is about 10 m (the
// layers document's OUTLINE_TILE_MAX_ZOOM).
const outlineMaxZoom = 10

// countyMergeBelow and cityMergeBelow are the zooms below which a locked County or City level
// sends one veil for the places the account hasn't been in, a zoom below the level's band
// (apps/web/src/map/coverageGroup.ts): further out a county or town is a few pixels, and every one
// of them as its own outline made a z6 tile of central France's towns 673 KB, about 100,000
// vertices. One zoom out of the band, France's towns are still 265 KB.
const (
	countyMergeBelow = 5
	cityMergeBelow   = 7
)

// visibleOutline is the narrowest a merged tile draws a place the account has been in, in tile
// units: two screen pixels.
const visibleOutline = 2 * pixel

// seaID is the admin_id of a tile's sea: the tile's frame with every outline in it cut out.
// Outline ids start at 1.
const seaID = 0

// exploredID is the admin_id of a merged tile's one feature for every place the account has been
// in (mergedGeoms), of kind 'explored': a client names no kind it doesn't know, and outlines it.
const exploredID = -1

// liveGeoms draws every outline in tile ($1, $2, $3), transformed and clipped to it, and the
// tile's sea, so the veil covers the water and what drops out too. The same for every account, so
// serveAdminTile keeps it in admin_tile_geoms rather than drawing it on every request:
// transforming and clipping is most of a tile's cost (docs/PERFORMANCE.md, 2026-10-09 dev, over
// 80 ms for the world's z0 Country tile), and the sea's union over a second for it.
//
// The outlines are simplified to a pixel together, as a coverage, so neighbours keep their
// shared border and no sliver of veil opens between them; one by one, each moved its side
// separately. Clipping and the tile grid treat a shared border the same on both sides. A piece
// (an island, a whole place) narrower than minOutlineAtZ0 drops out first: it shares no border it
// could open, and Canada's islets kept every ring through the coverage.
//
// The sea is veilOutside the outlines.
func (l adminLayer) liveGeoms() string {
	return fmt.Sprintf(`
		WITH piece AS (
			SELECT o.id, p.geom
			FROM %[1]s o, ST_Dump(ST_Transform(CASE WHEN $1 <= %[5]d THEN COALESCE(o.geom_far, o.geom) ELSE o.geom END, 3857)) p
			WHERE o.geom && ST_Transform(ST_TileEnvelope($1, $2, $3), 4326)
		), kept AS (
			SELECT id, ST_AsMVTGeom(ST_Collect(geom), ST_TileEnvelope($1, $2, $3), 4096, 64, true) AS geom
			FROM piece
			WHERE greatest(ST_XMax(geom) - ST_XMin(geom), ST_YMax(geom) - ST_YMin(geom)) >= %[2]f / power(2, $1::int)
			GROUP BY id
		), outlines AS (
			SELECT id AS admin_id, ST_SetSRID(ST_CoverageSimplify(geom, %[4]d) OVER (), 3857) AS geom
			FROM kept WHERE geom IS NOT NULL
		)
		SELECT admin_id, geom FROM outlines WHERE NOT ST_IsEmpty(geom)
		UNION ALL
		SELECT %[3]d, geom FROM (SELECT %[6]s AS geom FROM outlines) sea WHERE NOT ST_IsEmpty(geom)`, l.outlines, minOutlineAtZ0, seaID, pixel, farMaxZoom, veilOutside("outlines"))
}

// veilOutside is the SQL for an aggregate over `rows`, outlines on tile ($1, $2, $3)'s grid: the
// tile's frame with them cut out, empty where nothing is left. The frame reaches just past the
// tile, as fog.veilPolygons' does, so no edge falls on the tile's border, where antialiasing drew
// a seam; at the world's top and bottom it stops at the edge, as the globe draws what lies past it
// over the pole, once per tile in the row. GEOS winds a difference's outer ring the other way
// from ST_AsMVTGeom, and a vector tile reads that as a hole. The difference adds vertices between
// the grid's points, and ST_AsMVT rounds them, which can cross a ring over itself; MapLibre then
// leaves the polygon unfilled, so the veil is snapped to the grid here, staying valid.
func veilOutside(rows string) string {
	frame := `ST_MakeEnvelope(
			-2, CASE WHEN $3 = 0 THEN 0 ELSE -2 END,
			4098, CASE WHEN $3 = power(2, $1)::int - 1 THEN 4096 ELSE 4098 END, 3857)`
	return fmt.Sprintf(`ST_ForcePolygonCCW(ST_CollectionExtract(ST_ReducePrecision(
			COALESCE(ST_Difference(%[1]s, ST_Union(%[2]s.geom)), %[1]s), 1), 3))`, frame, rows)
}

// tileQuery is one account's tile ($1, $2, $3) of this layer, for account $4, with names in
// language $5: every outline, whether the account has been in it (`visited`), its kind, type,
// name, the places it lies in (`within`) and its counts, and the sea. Fog veils the sea and the unvisited,
// draws every outline's border, and names the one under the pointer from the rest.
//
// visited starts from the account's own activities, so its cost is the account's history,
// not every account's matches in the outlines the tile covers. It answers two columns: whether
// the tile is in admin_tile_geoms yet (always true for a live one) and the tile itself, its
// features in outline order whichever way it was drawn.
func (l adminLayer) tileQuery(cached bool) string {
	counts := ""
	if l.counts != "" {
		counts = l.counts + ",\n\t\t                   "
	}
	built, geoms := "true", l.liveGeoms()
	if cached {
		built = fmt.Sprintf(`EXISTS (
			SELECT 1 FROM admin_tiles_built
			WHERE layer = '%s' AND zoom = $1 AND tile_x = $2 AND tile_y = $3)`, l.cache)
		geoms = fmt.Sprintf(`
			SELECT admin_id, geom FROM admin_tile_geoms
			WHERE layer = '%s' AND zoom = $1 AND tile_x = $2 AND tile_y = $3`, l.cache)
	}
	if l.mergeBelow > 0 {
		geoms = l.mergedGeoms(geoms)
	}
	return fmt.Sprintf(`
		WITH %[1]s
		SELECT %[2]s,
		       (SELECT ST_AsMVT(t, '%[3]s', 4096, 'geom')
		        FROM (
		            SELECT g.admin_id AS id,
		                   v.id IS NOT NULL OR g.admin_id = %[12]d AS visited,
		                   CASE g.admin_id WHEN %[6]d THEN 'sea' WHEN %[12]d THEN 'explored' ELSE %[5]s END AS kind,
		                   %[8]s AS type,
		                   COALESCE(o.names ->> $5::text, o.name) AS name,
		                   %[9]s AS within,
		                   %[11]sg.geom
		            FROM (%[4]s) g
		            LEFT JOIN (SELECT DISTINCT id FROM %[10]s) v ON v.id = g.admin_id
		            LEFT JOIN %[7]s o ON o.id = g.admin_id
		            ORDER BY g.admin_id
		        ) t)`, visitedCTEs("$4"), built, l.name, geoms, l.kind, seaID, l.outlines, l.localType, l.within, l.visited, counts, exploredID)
}

// mergedGeoms is a tile's outlines `geoms` as a level that merges draws them: from mergeBelow up,
// all of them; below it, two features, the places the account has been in as one (exploredID)
// and the rest and the sea as the veil, cut from it, so the two meet exactly. Merging the explored
// places too keeps a tile's size and cost to the outline of where the account has been, not the
// count of places in it: one account with three coast-to-coast routes, 4,687 towns, made the
// world's City tile 303 KB and its County tile 4.4 s, counting each county's towns.
//
// Below mergeBelow the places come from their outlines rather than the tile's cache, which drops a
// piece narrower than minOutlineAtZ0: there that is most towns, and a merged tile exists to show
// where the account has been. One narrower than visibleOutline is drawn as a dot that wide, round
// a point inside it. Simplifying the union can cross a hole with its ring, so it is made valid
// before it is snapped to the grid.
func (l adminLayer) mergedGeoms(geoms string) string {
	return fmt.Sprintf(`
		SELECT admin_id, geom FROM (%[1]s) a WHERE $1 >= %[2]d
		UNION ALL (
			-- Materialized one step at a time and led by the account's places, each looked up by
			-- its id and boxed by its far drawing, so a prepared statement's generic plan neither
			-- scans every place for them, nor reads their full outlines, nor draws each shape again
			-- for every use of it: together they made a z0 tile take over a minute.
			WITH mine_shape AS MATERIALIZED (
				SELECT o.id, ST_Transform(COALESCE(o.geom_far, o.geom), 3857) AS m
				FROM (SELECT DISTINCT id FROM %[3]s) v, LATERAL (
					SELECT o.id, o.geom_far, o.geom FROM %[7]s o
					WHERE o.id = v.id AND COALESCE(o.geom_far, o.geom) && ST_Transform(ST_TileEnvelope($1, $2, $3), 4326)
				) o
				WHERE $1 < %[2]d
			), mine_clip AS MATERIALIZED (
				SELECT m, ST_AsMVTGeom(m, ST_TileEnvelope($1, $2, $3), 4096, 64, true) AS g FROM mine_shape
			), explored AS MATERIALIZED (
				SELECT ST_ForcePolygonCCW(ST_CollectionExtract(ST_ReducePrecision(ST_MakeValid(ST_SimplifyPreserveTopology(ST_Union(
				       CASE WHEN g IS NULL OR greatest(ST_XMax(g) - ST_XMin(g), ST_YMax(g) - ST_YMin(g)) < %[6]d
				            THEN ST_Buffer(ST_AsMVTGeom(ST_PointOnSurface(m), ST_TileEnvelope($1, $2, $3), 4096, 64, true), %[6]d / 2.0, 2)
				            ELSE g END), %[9]d / 2.0)), 1), 3)) AS geom
				FROM mine_clip HAVING $1 < %[2]d
			)
			SELECT %[8]d, geom FROM explored WHERE geom IS NOT NULL AND NOT ST_IsEmpty(geom)
			UNION ALL
			SELECT %[4]d, geom FROM (SELECT %[5]s AS geom FROM explored HAVING $1 < %[2]d) veil
			WHERE NOT ST_IsEmpty(geom)
		)`, geoms, l.mergeBelow, l.visited, seaID, veilOutside("explored"), visibleOutline, l.outlines, exploredID, pixel)
}

// adminTileQueries are the two handlers' queries, cached and live, built once.
type adminTileQueries struct{ cached, live string }

var (
	countryFogQueries = adminTileQueries{countryLayer.tileQuery(true), countryLayer.tileQuery(false)}
	regionFogQueries  = adminTileQueries{regionLayer.tileQuery(true), regionLayer.tileQuery(false)}
	countyFogQueries  = adminTileQueries{countyLayer.tileQuery(true), countyLayer.tileQuery(false)}
	cityFogQueries    = adminTileQueries{cityLayer.tileQuery(true), cityLayer.tileQuery(false)}
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
	// The names' language comes in the path (the layers document's `lang`), so a tile cached under
	// the tile version changes with it; a path without one gets the request's.
	lang := r.URL.Query().Get("lang")
	if !i18n.IsSupported(lang) {
		lang = requestLang(r)
	}
	err := s.pool.QueryRow(ctx, query, z, x, y, userIDFromContext(ctx), lang).Scan(&built, &tile)
	if err == nil && !built {
		if err = s.buildAdminTile(ctx, l, z, x, y); err == nil {
			err = s.pool.QueryRow(ctx, query, z, x, y, userIDFromContext(ctx), lang).Scan(&built, &tile)
		}
	}
	if err != nil {
		if clientGone(w, r) {
			return
		}
		s.log.Error("admin tile query failed", "err", err, "layer", l.name, "z", z)
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
