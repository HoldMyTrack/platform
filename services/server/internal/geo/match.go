package geo

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"
)

// MatchActivity records which places on every level activityID's trajectory touches: countries,
// regions, counties and cities, the latter two with the stand-ins that fill their levels' gaps.
// Called once from ingest.Process right after the activity row is persisted; each query reads
// activities.trajectory back by id rather than taking geometry as a parameter, so nothing
// upstream needs to hold onto it for this.
//
// Matches against the already-persisted display trajectory, not the raw pre-simplification
// points fog masks use: ingest's ~3 m simplification tolerance is well inside the outlines' own
// accuracy, and reading the column back avoids a second geometry pass in Go. It tests the
// outlines' pieces (admin_*_parts), never the simplified ones the tiles draw. Every polygon
// touched gets a row, however briefly, matching the product requirement that a visit's size or
// duration doesn't matter, only whether it happened. A place above a matched one is cleared
// through the tiles' parent chain, not here (internal/httpapi's adminLayer).
func MatchActivity(ctx context.Context, pool *pgxpool.Pool, activityID string) error {
	for _, level := range []struct{ matches, id, parts string }{
		{"activity_country", "country_id", "admin_country_parts"},
		{"activity_region", "region_id", "admin_region_parts"},
		{"activity_county", "county_id", "admin_county_parts"},
		{"activity_city", "city_id", "admin_city_parts"},
	} {
		_, err := pool.Exec(ctx, `
			INSERT INTO `+level.matches+` (activity_id, `+level.id+`)
			SELECT DISTINCT $1::uuid, p.`+level.id+` FROM `+level.parts+` p
			WHERE ST_Intersects(p.geom, (SELECT `+WrappedSQL("trajectory")+` FROM activities WHERE id = $1))
			ON CONFLICT DO NOTHING
		`, activityID)
		if err != nil {
			return fmt.Errorf("geo: match %s: %w", level.matches, err)
		}
	}
	return nil
}

// WrappedSQL is the SQL for the geometry col names moved into −180…180: a trajectory stored
// continuing past ±180 across the antimeridian (IMPLEMENTATION.md §4.1) comes back as parts,
// one each side, which is what testing it against the world's outlines needs. A geometry
// already inside comes back as it is.
func WrappedSQL(col string) string {
	return `ST_WrapX(ST_WrapX(` + col + `, 180, -360), -180, 360)`
}
