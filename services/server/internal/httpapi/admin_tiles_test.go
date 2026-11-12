package httpapi

import (
	"bytes"
	"context"
	"fmt"
	"net/http"
	"testing"
	"time"

	"github.com/HoldMyTrack/platform/services/server/internal/tilemath"
)

// The Country and Region tiles are drawn from outlines kept per tile (admin_tile_geoms): the
// first request builds a tile, which then serves exactly what drawing it live would, and a
// later one reads it back without building it again.
func TestAdminTilesAreBuiltOnceAndMatchTheLiveQuery(t *testing.T) {
	d := newDBTest(t)
	ctx := context.Background()
	at := [2]float64{-24.75, -44.5} // lon, lat: open ocean in the South Atlantic

	// Two countries side by side, each a region of its own, the account's activity in the west.
	stamp := time.Now().UnixNano()
	var visited, unvisited, region, eastRegion int
	if err := d.pool.QueryRow(ctx, `
		INSERT INTO admin_countries (code, name, geom)
		VALUES ($1, 'West', ST_Multi(ST_MakeEnvelope(-25, -45, -24.5, -44, 4326))) RETURNING id`,
		fmt.Sprintf("TW%d", stamp)).Scan(&visited); err != nil {
		t.Fatal(err)
	}
	if err := d.pool.QueryRow(ctx, `
		INSERT INTO admin_countries (code, name, geom)
		VALUES ($1, 'East', ST_Multi(ST_MakeEnvelope(-24.5, -45, -24, -44, 4326))) RETURNING id`,
		fmt.Sprintf("TE%d", stamp)).Scan(&unvisited); err != nil {
		t.Fatal(err)
	}
	if err := d.pool.QueryRow(ctx, `
		INSERT INTO admin_regions (country_id, overture_id, name, geom)
		VALUES ($1, $2, 'West', ST_Multi(ST_MakeEnvelope(-25, -45, -24.5, -44, 4326))) RETURNING id`,
		visited, fmt.Sprintf("test-region-w-%d", stamp)).Scan(&region); err != nil {
		t.Fatal(err)
	}
	if err := d.pool.QueryRow(ctx, `
		INSERT INTO admin_regions (country_id, overture_id, name, geom)
		VALUES ($1, $2, 'East', ST_Multi(ST_MakeEnvelope(-24.5, -45, -24, -44, 4326))) RETURNING id`,
		unvisited, fmt.Sprintf("test-region-e-%d", stamp)).Scan(&eastRegion); err != nil {
		t.Fatal(err)
	}

	type tileCase struct {
		path    string
		layer   adminLayer
		queries adminTileQueries
	}
	cases := []tileCase{
		{"countries", countryLayer, countryFogQueries},
		{"regions", regionLayer, regionFogQueries},
	}
	// A cached zoom whose tile holds both countries and the ocean round them.
	coords := func(l adminLayer) (int, int, int) {
		const z = 5
		x, y := tilemath.LonLatToTile(at[0], at[1], z)
		return z, x, y
	}
	forget := func() {
		for _, l := range []adminLayer{countryLayer, regionLayer} {
			z, x, y := coords(l)
			for _, table := range []string{"admin_tiles_built", "admin_tile_geoms"} {
				if _, err := d.pool.Exec(context.Background(),
					`DELETE FROM `+table+` WHERE layer = $1 AND zoom = $2 AND tile_x = $3 AND tile_y = $4`, l.cache, z, x, y); err != nil {
					t.Error(err)
				}
			}
		}
	}
	forget()
	t.Cleanup(func() {
		forget()
		ctx := context.Background()
		d.pool.Exec(ctx, `DELETE FROM admin_regions WHERE id = ANY($1)`, []int{region, eastRegion})
		d.pool.Exec(ctx, `DELETE FROM admin_countries WHERE id = ANY($1)`, []int{visited, unvisited})
	})

	me := d.newAccount(false) // deleted, with its matches, before the outlines above
	activity := d.newActivity(me, testActivity{activityType: "walking", at: &at})
	for _, s := range []struct {
		sql  string
		args []any
	}{
		{`INSERT INTO activity_country VALUES ($1, $2)`, []any{activity, visited}},
		{`INSERT INTO activity_region VALUES ($1, $2)`, []any{activity, region}},
	} {
		if _, err := d.pool.Exec(ctx, s.sql, s.args...); err != nil {
			t.Fatal(err)
		}
	}

	get := func(c tileCase) []byte {
		t.Helper()
		z, x, y := coords(c.layer)
		rec := d.do(me, "GET", fmt.Sprintf("/tiles/v1/%s/%d/%d/%d.mvt", c.path, z, x, y), nil)
		if rec.Code != http.StatusOK {
			t.Fatalf("%s: status %d", c.path, rec.Code)
		}
		return rec.Body.Bytes()
	}
	for _, c := range cases {
		served := get(c)
		z, x, y := coords(c.layer)
		var built bool
		var live []byte
		if err := d.pool.QueryRow(ctx, c.queries.live, z, x, y, me.id, "en").Scan(&built, &live); err != nil {
			t.Fatalf("%s live: %v", c.path, err)
		}
		if len(served) == 0 || !bytes.Equal(served, live) {
			t.Errorf("%s: served %d bytes, drawing it live gives %d, want the same non-empty tile", c.path, len(served), len(live))
		}
	}

	// The sea is veiled with the locked outlines: with them it covers the tile, it overlaps no
	// land, and it is wound as they are, so the tile draws it as ground rather than as a hole.
	for _, c := range cases {
		z, x, y := coords(c.layer)
		var gap, overlap float64
		var wound bool
		if err := d.pool.QueryRow(ctx, `
			SELECT ST_Area(ST_Difference(ST_MakeEnvelope(0, 0, 4096, 4096, 3857), ST_Union(s.geom, ST_Union(o.geom)))),
			       ST_Area(ST_Intersection(s.geom, ST_Union(o.geom))),
			       ST_IsPolygonCCW(s.geom)
			FROM admin_tile_geoms s JOIN admin_tile_geoms o USING (layer, zoom, tile_x, tile_y)
			WHERE s.layer = $1 AND s.zoom = $2 AND s.tile_x = $3 AND s.tile_y = $4
			  AND s.admin_id = $5 AND o.admin_id <> $5
			GROUP BY s.geom`, c.layer.cache, z, x, y, seaID).Scan(&gap, &overlap, &wound); err != nil {
			t.Fatalf("%s sea: %v", c.path, err)
		}
		if gap > 1 || overlap > 1 || !wound {
			t.Errorf("%s: the sea leaves %.0f units of the tile bare, overlaps %.0f of land, wound like the outlines %v", c.path, gap, overlap, wound)
		}
	}

	// Built once: with its outlines taken away behind its back, the tile is read back empty
	// rather than drawn again.
	z, x, y := coords(countryLayer)
	if _, err := d.pool.Exec(ctx,
		`DELETE FROM admin_tile_geoms WHERE layer = 'countries' AND zoom = $1 AND tile_x = $2 AND tile_y = $3`, z, x, y); err != nil {
		t.Fatal(err)
	}
	if n := len(get(cases[0])); n != 0 {
		t.Errorf("a built tile was drawn again: %d bytes", n)
	}
}

// Past the world's top and bottom edges the globe draws a tile's sea over the pole, once per tile
// in the row, so there the sea stops at the edge; elsewhere it reaches just past the tile.
func TestAdminTileSeaStopsAtTheWorldsEdge(t *testing.T) {
	d := newDBTest(t)
	for _, c := range []struct {
		z, x, y     int
		top, bottom float64
	}{
		{0, 0, 0, 0, 4096},
		{2, 1, 0, 0, 4098},
		{2, 1, 1, -2, 4098},
		{2, 1, 3, -2, 4096},
	} {
		var top, bottom float64
		if err := d.pool.QueryRow(context.Background(), `
			SELECT ST_YMin(g.geom), ST_YMax(g.geom) FROM (`+countryLayer.liveGeoms()+`) g WHERE g.admin_id = $4`,
			c.z, c.x, c.y, seaID).Scan(&top, &bottom); err != nil {
			t.Fatalf("tile %d/%d/%d: %v", c.z, c.x, c.y, err)
		}
		if top != c.top || bottom != c.bottom {
			t.Errorf("tile %d/%d/%d: the sea spans y %v to %v, want %v to %v", c.z, c.x, c.y, top, bottom, c.top, c.bottom)
		}
	}
}

// The sea is cut out of outlines already on the tile's grid, but where an outline's edge crosses
// the frame the cut adds a vertex between grid points. Encoding rounds it, which can cross a ring
// over itself, and MapLibre leaves such a polygon unfilled, so the sea comes out on the grid.
func TestAdminTileSeaIsOnTheTileGrid(t *testing.T) {
	d := newDBTest(t)
	ctx := context.Background()
	// A country whose long edge crosses tile 3/3/5's frame on the slant, in the South Atlantic.
	var id int
	if err := d.pool.QueryRow(ctx, `
		INSERT INTO admin_countries (code, name, geom)
		VALUES ($1, 'Slant', ST_Multi(ST_GeomFromText('POLYGON((-60 -60, 10 -60, -60 -20, -60 -60))', 4326))) RETURNING id`,
		fmt.Sprintf("TS%d", time.Now().UnixNano())).Scan(&id); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { d.pool.Exec(context.Background(), `DELETE FROM admin_countries WHERE id = $1`, id) })

	var offGrid int
	var valid bool
	if err := d.pool.QueryRow(ctx, `
		SELECT (SELECT count(*) FROM ST_DumpPoints(g.geom) p
		        WHERE ST_X(p.geom) <> round(ST_X(p.geom)) OR ST_Y(p.geom) <> round(ST_Y(p.geom))),
		       ST_IsValid(g.geom)
		FROM (`+countryLayer.liveGeoms()+`) g WHERE g.admin_id = $4`, 3, 3, 5, seaID).Scan(&offGrid, &valid); err != nil {
		t.Fatal(err)
	}
	if offGrid != 0 || !valid {
		t.Errorf("the sea has %d vertices off the tile grid, valid %v; want none, valid", offGrid, valid)
	}
}

// Below a level's merge zoom a tile holds two features: where the account has been, as one, and
// the veil for the rest cut from it, which together cover the tile without overlapping. From the
// merge zoom up every place is its own outline again. A place the account has been in that is too
// narrow for the tile's cache, as most towns are there, still clears, two pixels wide.
func TestCityTileMergesThePlacesNotBeenInBelowItsBand(t *testing.T) {
	d := newDBTest(t)
	ctx := context.Background()
	at := [2]float64{-24.75, -44.5} // lon, lat: open ocean in the South Atlantic
	stamp := time.Now().UnixNano()

	var country, west, east, speck int
	if err := d.pool.QueryRow(ctx, `
		INSERT INTO admin_countries (code, name, geom)
		VALUES ($1, 'Isle', ST_Multi(ST_MakeEnvelope(-25, -44.6, -24.5, -44.4, 4326))) RETURNING id`,
		fmt.Sprintf("TM%d", stamp)).Scan(&country); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		name           string
		x0, y0, x1, y1 float64
		id             *int
	}{
		{"West", -25, -44.6, -24.75, -44.4, &west},
		{"East", -24.75, -44.6, -24.5, -44.4, &east},
		{"Speck", -24.405, -44.505, -24.395, -44.495, &speck}, // about 1 km: under a pixel at z6
	} {
		if err := d.pool.QueryRow(ctx, `
			INSERT INTO admin_cities (overture_id, kind, country_id, name, geom)
			VALUES ($1, 'city', $2, $3, ST_Multi(ST_MakeEnvelope($4, $5, $6, $7, 4326))) RETURNING id`,
			fmt.Sprintf("test-city-%s-%d", c.name, stamp), country, c.name, c.x0, c.y0, c.x1, c.y1).Scan(c.id); err != nil {
			t.Fatal(err)
		}
	}
	t.Cleanup(func() {
		ctx := context.Background()
		d.pool.Exec(ctx, `DELETE FROM admin_cities WHERE id = ANY($1)`, []int{west, east, speck})
		d.pool.Exec(ctx, `DELETE FROM admin_countries WHERE id = $1`, country)
	})

	me := d.newAccount(false) // deleted, with its matches, before the outlines above
	activity := d.newActivity(me, testActivity{activityType: "walking", at: &at})
	if _, err := d.pool.Exec(ctx, `INSERT INTO activity_city VALUES ($1, $2), ($1, $3)`, activity, west, speck); err != nil {
		t.Fatal(err)
	}

	for _, c := range []struct {
		z    int
		want []int
	}{
		{cityMergeBelow - 1, []int{exploredID, seaID}},
		{cityMergeBelow, []int{seaID, west, east}}, // the speck drops out of the cached outlines
	} {
		x, y := tilemath.LonLatToTile(at[0], at[1], c.z)
		var ids []int
		var gap, overlap float64
		var cleared []bool
		if err := d.pool.QueryRow(ctx, `
			WITH `+visitedCTEs("$4")+`, g AS (`+cityLayer.mergedGeoms(cityLayer.liveGeoms())+`),
			pt AS (
				SELECT ST_AsMVTGeom(ST_Transform(ST_SetSRID(ST_MakePoint(lon, -44.5), 4326), 3857), ST_TileEnvelope($1, $2, $3), 4096, 64, true) AS p, n
				FROM (VALUES (-24.875, 1), (-24.625, 2), (-24.4, 3)) AS v(lon, n)
			)
			SELECT array_agg(admin_id ORDER BY admin_id),
			       ST_Area(ST_Difference(ST_MakeEnvelope(0, 0, 4096, 4096, 3857), ST_Union(geom))),
			       COALESCE((SELECT ST_Area(ST_Intersection(s.geom, ST_Union(o.geom)))
			                 FROM g s JOIN g o ON o.admin_id <> s.admin_id WHERE s.admin_id = $5 GROUP BY s.geom), 0),
			       (SELECT array_agg(EXISTS (SELECT 1 FROM g WHERE admin_id = $6 AND ST_Intersects(g.geom, pt.p)) ORDER BY n) FROM pt)
			FROM g`, c.z, x, y, me.id, seaID, exploredID).Scan(&ids, &gap, &overlap, &cleared); err != nil {
			t.Fatalf("z%d: %v", c.z, err)
		}
		if fmt.Sprint(ids) != fmt.Sprint(c.want) || gap > 1 || overlap > 1 {
			t.Errorf("z%d: features %v, want %v; %.0f units of the tile bare, the veil over %.0f of the places", c.z, ids, c.want, gap, overlap)
		}
		if c.z < cityMergeBelow && fmt.Sprint(cleared) != "[true false true]" {
			t.Errorf("z%d: West, East and the speck cleared %v, want [true false true]", c.z, cleared)
		}
	}
}

// A vector tile reads a ring wound against its polygon's as a hole, and MapLibre left that part
// of the place unfilled, so it looked cleared: every outline in a tile is wound as the sea is,
// whichever way its source's rings ran.
func TestAdminTileOutlinesAreWoundAsTheSea(t *testing.T) {
	d := newDBTest(t)
	ctx := context.Background()
	stamp := time.Now().UnixNano()
	var ids []int
	for i, wkt := range []string{
		"MULTIPOLYGON(((-25 -45, -24.5 -45, -24.5 -44, -25 -44, -25 -45)))",                                                               // counter-clockwise
		"MULTIPOLYGON(((-24.5 -45, -24.5 -44, -24 -44, -24 -45, -24.5 -45)))",                                                             // clockwise
		"MULTIPOLYGON(((-25 -46, -24.5 -46, -24.5 -45.5, -25 -45.5, -25 -46)),((-24.4 -46, -24.4 -45.5, -24 -45.5, -24 -46, -24.4 -46)))", // one of each
	} {
		var id int
		if err := d.pool.QueryRow(ctx, `
			INSERT INTO admin_countries (code, name, geom) VALUES ($1, 'Wound', ST_GeomFromText($2, 4326)) RETURNING id`,
			fmt.Sprintf("W%d%d", i, stamp), wkt).Scan(&id); err != nil {
			t.Fatal(err)
		}
		ids = append(ids, id)
	}
	t.Cleanup(func() { d.pool.Exec(context.Background(), `DELETE FROM admin_countries WHERE id = ANY($1)`, ids) })

	x, y := tilemath.LonLatToTile(-24.5, -45, 5)
	rows, err := d.pool.Query(ctx, `SELECT g.admin_id, ST_IsPolygonCCW(g.geom) FROM (`+countryLayer.liveGeoms()+`) g`, 5, x, y)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	seen := 0
	for rows.Next() {
		var id int
		var ccw bool
		if err := rows.Scan(&id, &ccw); err != nil {
			t.Fatal(err)
		}
		if !ccw {
			t.Errorf("outline %d is not wound as the sea", id)
		}
		seen++
	}
	if seen < len(ids)+1 {
		t.Errorf("%d features in the tile, want the %d countries and the sea", seen, len(ids))
	}
}
