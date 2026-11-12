package geo

import (
	"bytes"
	"compress/gzip"
	"context"
	"fmt"
	"log/slog"
	"math"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/HoldMyTrack/platform/services/server/internal/db"
)

// testTx is a transaction on TEST_DATABASE_URL, rolled back when the test ends (skipped without
// one — docs/DEVELOPMENT.md). The load replaces every outline and every activity's matches, so
// it runs here: no other test sees what it did.
func testTx(t *testing.T) pgx.Tx {
	t.Helper()
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	pool, err := db.Open(ctx, url)
	if err != nil {
		t.Fatalf("open test database: %v", err)
	}
	t.Cleanup(pool.Close)
	if err := db.Migrate(ctx, pool); err != nil {
		t.Fatalf("migrate test database: %v", err)
	}
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatalf("begin: %v", err)
	}
	t.Cleanup(func() { tx.Rollback(context.Background()) })
	return tx
}

// A load replaces the outlines of every level, gives a country with no regions one region that is
// all of it, leaves out a region whose country isn't there, links each county and city to the
// places above, re-matches activities against the full-detail pieces and moves the tile version;
// loading the same extract again does nothing, and one with too few outlines is refused.
func TestLoadBoundaries(t *testing.T) {
	tx := testTx(t)
	ctx := context.Background()
	log := slog.New(slog.DiscardHandler)

	box := func(lon1, lat1, lon2, lat2 float64) string {
		var hex string
		if err := tx.QueryRow(ctx, `SELECT encode(ST_AsBinary(ST_MakeEnvelope($1, $2, $3, $4)), 'hex')`,
			lon1, lat1, lon2, lat2).Scan(&hex); err != nil {
			t.Fatal(err)
		}
		return hex
	}
	// Two countries side by side in the South Atlantic, where no real outline is; AA has a
	// region over its west half, BB none, and ZZ-1's country isn't in the file. CC is smaller
	// than the tiles' simplifying can keep, so it keeps its full outline. West Aland is one
	// county, Westshire, with one town; on the City level the rest of Westshire stands in, and
	// on the County level Bland stands in for itself.
	file := func(rows ...string) *bytes.Buffer {
		var buf bytes.Buffer
		gz := gzip.NewWriter(&buf)
		gz.Write([]byte(strings.Join(rows, "\n") + "\n"))
		gz.Close()
		return &buf
	}
	extract := func() *bytes.Buffer {
		return file(
			"country,country,AA,AA,,,,,Aland,{},"+box(-41, -61, -40, -60),
			"country,country,BB,BB,,,,,\"Bland, the\",{},"+box(-40, -61, -39, -60),
			"country,country,CC,CC,,,,,Cland,{},"+box(-38, -61, -37.999, -60.999),
			"region,region,div-aa-1,AA,,,AA-1,state,West Aland,\"{\"\"ru\"\": \"\"Западный Аланд\"\"}\","+box(-41, -61, -40.5, -60),
			"region,region,div-zz-1,ZZ,,,ZZ-1,,Nowhere,{},"+box(-30, -61, -29, -60),
			"county,county,div-aa-c1,AA,div-aa-1,,,county,Westshire,{},"+box(-41, -61, -40.5, -60),
			"county,country,rest:country:BB,BB,country:BB,,,,\"Bland, the\",{},"+box(-40, -61, -39, -60),
			"city,city,div-aa-t1,AA,div-aa-1,div-aa-c1,,town,Westtown,{},"+box(-40.9, -60.6, -40.7, -60.4),
			"city,county,rest:div-aa-c1,AA,div-aa-1,div-aa-c1,,county,Westshire,{},"+box(-41, -61, -40.5, -60),
		)
	}

	var userID, activityID string
	if err := tx.QueryRow(ctx, `INSERT INTO users (email) VALUES ($1) RETURNING id`,
		fmt.Sprintf("geo-seed-%d@holdmytrack.invalid", time.Now().UnixNano())).Scan(&userID); err != nil {
		t.Fatalf("create account: %v", err)
	}
	// From West Aland into Bland, never touching Aland's east half on its own.
	if err := tx.QueryRow(ctx, `
		INSERT INTO activities (user_id, source, activity_type, started_at, trajectory, timezone)
		VALUES ($1, 'upload', 'walking', now(), ST_GeomFromText('LINESTRING M(-40.8 -60.5 0, -39.5 -60.5 60)', 4326), 'UTC')
		RETURNING id`, userID).Scan(&activityID); err != nil {
		t.Fatalf("create activity: %v", err)
	}
	version := func() int64 {
		var v int64
		if err := tx.QueryRow(ctx, `SELECT map_version FROM users WHERE id = $1`, userID).Scan(&v); err != nil {
			t.Fatal(err)
		}
		return v
	}
	matched := func(sql string) string {
		var s string
		if err := tx.QueryRow(ctx, sql, activityID).Scan(&s); err != nil {
			t.Fatal(err)
		}
		return s
	}

	// A tile the Country tier drew from the old outlines (internal/httpapi's serveAdminTile).
	if _, err := tx.Exec(ctx, `
		INSERT INTO admin_tiles_built VALUES ('countries', 0, 0, 0);
		INSERT INTO admin_tile_geoms VALUES ('countries', 0, 0, 0, 1, ST_MakePoint(0, 0))`); err != nil {
		t.Fatal(err)
	}

	before := version()
	stats, err := loadBoundaries(ctx, tx, log, extract(), "test-1.csv.gz", false, minimums{3, 1, 1, 1})
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if stats.Countries != 3 || stats.Regions != 1 || stats.SkippedRegions != 1 || stats.WholeCountryRegions != 2 ||
		stats.Counties != 2 || stats.Cities != 2 {
		t.Errorf("stats %+v", stats)
	}
	if got := matched(`SELECT string_agg(c.code || ' ' || c.name, ', ' ORDER BY c.code)
		FROM activity_country ac JOIN admin_countries c ON c.id = ac.country_id WHERE ac.activity_id = $1`); got != "AA Aland, BB Bland, the" {
		t.Errorf("countries %q", got)
	}
	if got := matched(`SELECT string_agg(r.overture_id || ' ' || COALESCE(r.code, '-'), ', ' ORDER BY r.overture_id)
		FROM activity_region ar JOIN admin_regions r ON r.id = ar.region_id WHERE ar.activity_id = $1`); got != "country:BB -, div-aa-1 AA-1" {
		t.Errorf("regions %q", got)
	}
	if got := matched(`SELECT string_agg(k.overture_id || ' ' || k.kind || ' ' || COALESCE(r.overture_id, '-'), ', ' ORDER BY k.overture_id)
		FROM activity_county ak JOIN admin_counties k ON k.id = ak.county_id
		LEFT JOIN admin_regions r ON r.id = k.region_id WHERE ak.activity_id = $1`); got != "div-aa-c1 county div-aa-1, rest:country:BB country country:BB" {
		t.Errorf("counties %q", got)
	}
	if got := matched(`SELECT string_agg(c.overture_id || ' ' || c.kind || ' ' || k.overture_id || ' ' || c.local_type, ', ' ORDER BY c.overture_id)
		FROM activity_city ac JOIN admin_cities c ON c.id = ac.city_id
		JOIN admin_counties k ON k.id = c.county_id WHERE ac.activity_id = $1`); got != "div-aa-t1 city div-aa-c1 town, rest:div-aa-c1 county div-aa-c1 county" {
		t.Errorf("cities %q", got)
	}
	if got := matched(`SELECT names ->> 'ru' || ' ' || local_type FROM admin_regions WHERE overture_id = 'div-aa-1' AND $1::uuid IS NOT NULL`); got != "Западный Аланд state" {
		t.Errorf("West Aland's Russian name and type %q", got)
	}
	var tiny int
	if err := tx.QueryRow(ctx, `SELECT ST_NPoints(c.geom) + ST_NPoints(r.geom) FROM admin_countries c
		JOIN admin_regions r ON r.country_id = c.id WHERE c.code = 'CC'`).Scan(&tiny); err != nil || tiny != 10 {
		t.Errorf("Cland's outlines: %d points, %v", tiny, err)
	}
	if v := version(); v != before+1 {
		t.Errorf("map_version %d, want %d", v, before+1)
	}
	var kept int
	if err := tx.QueryRow(ctx, `SELECT (SELECT count(*) FROM admin_tiles_built) + (SELECT count(*) FROM admin_tile_geoms)`).Scan(&kept); err != nil || kept != 0 {
		t.Errorf("tiles drawn from the old outlines: %d rows kept, %v", kept, err)
	}

	stats, err = loadBoundaries(ctx, tx, log, extract(), "test-1.csv.gz", false, minimums{3, 1, 1, 1})
	if err != nil || !stats.Unchanged || version() != before+1 {
		t.Errorf("the same extract again: %+v, %v, version %d", stats, err, version())
	}

	if _, err := loadBoundaries(ctx, tx, log, extract(), "test-2.csv.gz", false, minimums{4, 1, 1, 1}); err == nil || !strings.Contains(err.Error(), "cut short") {
		t.Errorf("too few countries: %v", err)
	}
	if _, err := loadBoundaries(ctx, tx, log, extract(), "test-2.csv.gz", false, minimums{3, 1, 1, 2}); err == nil || !strings.Contains(err.Error(), "cut short") {
		t.Errorf("too few cities: %v", err)
	}
}

// A track stored continuing past 180 across the antimeridian (ingest's unwrapLons) matches the
// countries either side of it, and not one the same parallel crosses on the far side of the
// world.
func TestMatchAcrossTheAntimeridian(t *testing.T) {
	tx := testTx(t)
	ctx := context.Background()
	log := slog.New(slog.DiscardHandler)
	box := func(lon1, lat1, lon2, lat2 float64) string {
		var hex string
		if err := tx.QueryRow(ctx, `SELECT encode(ST_AsBinary(ST_MakeEnvelope($1, $2, $3, $4)), 'hex')`,
			lon1, lat1, lon2, lat2).Scan(&hex); err != nil {
			t.Fatal(err)
		}
		return hex
	}
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	gz.Write([]byte(strings.Join([]string{
		"country,country,EE,EE,,,,,East of it,{}," + box(179, -61, 180, -60),
		"country,country,WW,WW,,,,,West of it,{}," + box(-180, -61, -179, -60),
		"country,country,FF,FF,,,,,Far away,{}," + box(0, -61, 1, -60),
	}, "\n") + "\n"))
	gz.Close()

	var userID, activityID string
	if err := tx.QueryRow(ctx, `INSERT INTO users (email) VALUES ($1) RETURNING id`,
		fmt.Sprintf("geo-am-%d@holdmytrack.invalid", time.Now().UnixNano())).Scan(&userID); err != nil {
		t.Fatal(err)
	}
	if err := tx.QueryRow(ctx, `
		INSERT INTO activities (user_id, source, activity_type, started_at, trajectory, timezone)
		VALUES ($1, 'upload', 'sailing', now(), ST_GeomFromText('LINESTRING M(179.5 -60.5 0, 180.5 -60.5 60)', 4326), 'UTC')
		RETURNING id`, userID).Scan(&activityID); err != nil {
		t.Fatal(err)
	}
	if _, err := loadBoundaries(ctx, tx, log, &buf, "am.csv.gz", true, minimums{3, 0, 0, 0}); err != nil {
		t.Fatalf("load: %v", err)
	}
	var got string
	if err := tx.QueryRow(ctx, `SELECT string_agg(c.code, ',' ORDER BY c.code)
		FROM activity_country ac JOIN admin_countries c ON c.id = ac.country_id WHERE ac.activity_id = $1`, activityID).Scan(&got); err != nil {
		t.Fatal(err)
	}
	if got != "EE,WW" {
		t.Errorf("matched %q, want EE,WW", got)
	}
}

// The outlines the tiles draw, near and far, keep a shared border shared: two countries whose
// border wiggles at every scale neither pull apart nor overlap once simplified, as each simplified
// alone did at both tolerances.
func TestDrawingKeepsSharedBorders(t *testing.T) {
	tx := testTx(t)
	ctx := context.Background()
	log := slog.New(slog.DiscardHandler)
	// A border near -40 from -61 to -60: a sine 0.05° wide, steps of 0.003° and a jitter of 0.0004°.
	var zig []string
	for i := 0; i <= 1000; i++ {
		x := -40 + 0.05*math.Sin(float64(i)*0.02) + 0.003*float64((i/10)%3) + 0.0004*float64(i%2)
		zig = append(zig, fmt.Sprintf("%v %v", x, -61+float64(i)*0.001))
	}
	border := strings.Join(zig, ", ")
	var west, east string
	if err := tx.QueryRow(ctx, `
		SELECT encode(ST_AsBinary(ST_GeomFromText('POLYGON((-41 -61, '||$1||', -41 -60, -41 -61))')), 'hex'),
		       encode(ST_AsBinary(ST_GeomFromText('POLYGON((-39 -61, -39 -60, '||$2||', -39 -61))')), 'hex')`,
		border, reverse(zig)).Scan(&west, &east); err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	gz.Write([]byte("country,country,WZ,WZ,,,,,West,{}," + west + "\ncountry,country,EZ,EZ,,,,,East,{}," + east + "\n"))
	gz.Close()
	if _, err := loadBoundaries(ctx, tx, log, &buf, "zigzag.csv.gz", true, minimums{2, 0, 0, 0}); err != nil {
		t.Fatalf("load: %v", err)
	}
	for _, col := range []string{"geom", "geom_far"} {
		var gap, overlap float64
		if err := tx.QueryRow(ctx, `
			SELECT ST_Area(ST_Difference(ST_MakeEnvelope(-41, -61, -39, -60, 4326), ST_Union(`+col+`))),
			       ST_Area(ST_Intersection(min(`+col+`), max(`+col+`)))
			FROM admin_countries WHERE code IN ('WZ', 'EZ')`).Scan(&gap, &overlap); err != nil {
			t.Fatal(err)
		}
		if gap > 1e-9 || overlap > 1e-9 {
			t.Errorf("%s: %.2g square degrees between the two, %.2g over each other", col, gap, overlap)
		}
	}
}

// reverse is the points of a border in the other direction, joined as WKT.
func reverse(points []string) string {
	out := make([]string, len(points))
	for i, p := range points {
		out[len(points)-1-i] = p
	}
	return strings.Join(out, ", ")
}
