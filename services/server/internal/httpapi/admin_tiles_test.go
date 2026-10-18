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
		{"country-veil", countryLayer, countryFogQueries},
		{"region-veil", regionLayer, regionFogQueries},
	}
	coords := func(l adminLayer) (int, int, int) {
		x, y := tilemath.LonLatToTile(at[0], at[1], l.cacheMaxZoom)
		return l.cacheMaxZoom, x, y
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
		if err := d.pool.QueryRow(ctx, c.queries.live, z, x, y, me.id).Scan(&built, &live); err != nil {
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
		`DELETE FROM admin_tile_geoms WHERE layer = 'country-veil' AND zoom = $1 AND tile_x = $2 AND tile_y = $3`, z, x, y); err != nil {
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
