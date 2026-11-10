package geo

import (
	"compress/gzip"
	"context"
	"fmt"
	"io"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// PROTOTYPE (FOG_REWORK.md "Next step"): the city tier's places, cities and the county land
// outside them, from scripts/places-extract.sh's file. Kept apart from SeedAdminBoundaries so
// the tier can be reseeded without the 500 MB country and region file; if the tier holds, it
// joins that seed.

// placeTolerance is how far, in degrees, the outlines the place tiles draw may stray from the
// matched ones: about 50 m, under a pixel at zoom 10 (FOG_REWORK.md Findings 5).
const placeTolerance = 0.0005

// PlaceStats is what one run of SeedAdminPlaces did, with each step's time.
type PlaceStats struct {
	Places, Parts, Matches int64
	Steps                  []PlaceStep
}

// PlaceStep is one step's rows and time.
type PlaceStep struct {
	What string
	Rows int64
	Took time.Duration
}

// SeedAdminPlaces replaces every place with r's and re-matches every activity against them, in
// one transaction, then bumps every account's tile version and empties the place tiles.
func SeedAdminPlaces(ctx context.Context, pool *pgxpool.Pool, log *slog.Logger, r io.Reader) (PlaceStats, error) {
	var stats PlaceStats
	tx, err := pool.Begin(ctx)
	if err != nil {
		return stats, err
	}
	defer tx.Rollback(ctx)

	gz, err := gzip.NewReader(r)
	if err != nil {
		return stats, err
	}
	if _, err := tx.Exec(ctx, `
		CREATE TEMP TABLE place_csv (kind TEXT, key TEXT, country TEXT, region TEXT, name TEXT, geom TEXT) ON COMMIT DROP
	`); err != nil {
		return stats, err
	}
	start := time.Now()
	tag, err := tx.Conn().PgConn().CopyFrom(ctx, gz, `COPY place_csv FROM STDIN (FORMAT csv)`)
	if err != nil {
		return stats, fmt.Errorf("geo: load places: %w", err)
	}
	stats.Steps = append(stats.Steps, PlaceStep{"read", tag.RowsAffected(), time.Since(start)})
	log.Info("seed-admin-places: read", "rows", tag.RowsAffected(), "took", time.Since(start))

	steps := []struct {
		what string
		sql  string
		into *int64
	}{
		{"outlines", `
			CREATE TEMP TABLE place ON COMMIT DROP AS
			SELECT kind, key, country, NULLIF(region, '') AS region, name,
			       ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_SetSRID(geom::geometry, 4326)), 3)) AS geom
			FROM place_csv`, nil},
		{"old matches", `DELETE FROM activity_place`, nil},
		{"old places", `DELETE FROM admin_places`, nil},
		{"places", `
			INSERT INTO admin_places (kind, overture_id, country, region, name, geom)
			SELECT kind, key, country, region, name, ` + displayGeom("geom", placeTolerance) + `
			FROM place WHERE NOT ST_IsEmpty(geom)`, &stats.Places},
		{"parts", `
			INSERT INTO admin_place_parts (place_id, geom)
			SELECT a.id, (ST_Dump(ST_Subdivide(p.geom, 256))).geom
			FROM place p JOIN admin_places a ON a.overture_id = p.key`, &stats.Parts},
		{"analyze", `ANALYZE admin_place_parts`, nil},
		{"activity places", `
			INSERT INTO activity_place (activity_id, place_id)
			SELECT DISTINCT a.id, p.place_id FROM activities a JOIN admin_place_parts p ON ST_Intersects(p.geom, ` + WrappedSQL("a.trajectory") + `)`, &stats.Matches},
		{"tile versions", `UPDATE users SET map_version = map_version + 1`, nil},
		{"tiles", `DELETE FROM admin_tiles_built WHERE layer = 'places'`, nil},
		{"", `DELETE FROM admin_tile_geoms WHERE layer = 'places'`, nil},
	}
	for _, s := range steps {
		start := time.Now()
		tag, err := tx.Exec(ctx, s.sql)
		if err != nil {
			return stats, fmt.Errorf("geo: %s: %w", s.what, err)
		}
		if s.into != nil {
			*s.into = tag.RowsAffected()
		}
		if s.what != "" {
			stats.Steps = append(stats.Steps, PlaceStep{s.what, tag.RowsAffected(), time.Since(start)})
			log.Info("seed-admin-places: "+s.what, "rows", tag.RowsAffected(), "took", time.Since(start))
		}
	}
	return stats, tx.Commit(ctx)
}
