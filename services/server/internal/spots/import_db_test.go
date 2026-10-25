package spots

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/HoldMyTrack/platform/services/server/internal/db"
)

// testTx is a transaction on TEST_DATABASE_URL, rolled back when the test ends (skipped without
// one, like internal/httpapi's database tests — docs/DEVELOPMENT.md). A planet import retires
// every place it doesn't see, other tests' included, so it runs here, with spots locked against
// writes until the rollback and every place already in the database retired first: the run sees
// only the test's own places, and no other test sees what it did.
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
	for _, sql := range []string{
		`LOCK TABLE spots IN EXCLUSIVE MODE`,
		`UPDATE spots SET retired_at = now() WHERE retired_at IS NULL`,
	} {
		if _, err := tx.Exec(ctx, sql); err != nil {
			t.Fatalf("%s: %v", sql, err)
		}
	}
	return tx
}

// A refresh (docs/SPEC.md FR-15.1): an unchanged re-run changes nothing and leaves the tile version alone; a
// planet run retires what it didn't see, keeping its captures, and brings it back when it
// returns; a regional run retires nothing; and a run that would retire too much retires none.
func TestImportRetires(t *testing.T) {
	tx := testTx(t)
	ctx := context.Background()
	log := slog.New(slog.DiscardHandler)

	base := time.Now().UnixNano()
	line := func(n int, name string) string {
		return fmt.Sprintf(`{"type":"Feature","id":"n%d","geometry":{"type":"Point","coordinates":[-40.5,%f]},"properties":{"tourism":"viewpoint","name":%q}}`,
			base+int64(n), -60.5+float64(n)*0.01, name)
	}
	file := func(lines ...string) *strings.Reader { return strings.NewReader(strings.Join(lines, "\n") + "\n") }
	run := func(planet bool, maxRetired float64, lines ...string) (ImportStats, error) {
		t.Helper()
		return importPlaces(ctx, tx, log, file(lines...), planet, maxRetired)
	}
	retired := func(n int) bool {
		t.Helper()
		var at *time.Time
		if err := tx.QueryRow(ctx, `SELECT retired_at FROM spots WHERE osm_type = 'node' AND osm_id = $1`, base+int64(n)).Scan(&at); err != nil {
			t.Fatalf("place %d: %v", n, err)
		}
		return at != nil
	}
	var userID string
	if err := tx.QueryRow(ctx, `INSERT INTO users (email) VALUES ($1) RETURNING id`,
		fmt.Sprintf("spots-import-%d@holdmytrack.invalid", base)).Scan(&userID); err != nil {
		t.Fatalf("create account: %v", err)
	}
	version := func() int64 {
		t.Helper()
		var v int64
		if err := tx.QueryRow(ctx, `SELECT map_version FROM users WHERE id = $1`, userID).Scan(&v); err != nil {
			t.Fatalf("map_version: %v", err)
		}
		return v
	}

	v := version()
	stats, err := run(true, 1, line(1, "One"), line(2, "Two"), line(3, "Three"))
	if err != nil || stats.Imported != 3 || stats.Changed != 3 || stats.Retired != 0 {
		t.Fatalf("first run: %+v, %v", stats, err)
	}
	if version() != v+1 {
		t.Errorf("first run: the tile version should move")
	}

	v = version()
	stats, err = run(true, 1, line(1, "One"), line(2, "Two"), line(3, "Three"))
	if err != nil || stats.Imported != 3 || stats.Changed != 0 || stats.Retired != 0 {
		t.Fatalf("unchanged re-run: %+v, %v", stats, err)
	}
	if version() != v {
		t.Errorf("unchanged re-run: the tile version moved")
	}

	if _, err := tx.Exec(ctx, `INSERT INTO spot_captures (user_id, spot_id)
		SELECT $1, id FROM spots WHERE osm_type = 'node' AND osm_id = $2`, userID, base+3); err != nil {
		t.Fatalf("capture: %v", err)
	}
	stats, err = run(true, 1, line(1, "One renamed"), line(2, "Two"))
	if err != nil || stats.Changed != 1 || stats.Retired != 1 {
		t.Fatalf("a place renamed and one gone: %+v, %v", stats, err)
	}
	if retired(1) || retired(2) || !retired(3) {
		t.Errorf("only the place gone should be retired: %v %v %v", retired(1), retired(2), retired(3))
	}
	var captures int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM spot_captures WHERE user_id = $1`, userID).Scan(&captures); err != nil || captures != 1 {
		t.Errorf("the retired place's capture: %d (%v), want 1", captures, err)
	}

	stats, err = run(false, 1, line(1, "One renamed"))
	if err != nil || stats.Retired != 0 || retired(2) {
		t.Errorf("a regional run retired something: %+v, %v", stats, err)
	}

	stats, err = run(true, 1, line(1, "One renamed"), line(2, "Two"), line(3, "Three"))
	if err != nil || stats.Changed != 1 || stats.Retired != 0 || retired(3) {
		t.Errorf("a place back in OSM: %+v, %v, retired %v", stats, err, retired(3))
	}

	v = version()
	stats, err = run(true, 0.01, line(1, "One renamed"))
	if !errors.Is(err, ErrTooManyRetired) || stats.Retired != 0 || retired(2) || retired(3) {
		t.Errorf("retiring 2 of 3: %+v, %v; want ErrTooManyRetired and nothing retired", stats, err)
	}
	if version() != v {
		t.Errorf("a refused run that changed nothing moved the tile version")
	}
}

// Waterfalls (docs/SPEC.md FR-15.1): one with a viewpoint within 120 m stays out, even when the
// viewpoint comes later in the file, and the rest get a 75 m circle.
func TestImportWaterfalls(t *testing.T) {
	tx := testTx(t)
	ctx := context.Background()
	base := time.Now().UnixNano()
	const deg = 1.0 / 111320
	falls := func(n int, lat float64) string {
		return fmt.Sprintf(`{"type":"Feature","id":"n%d","geometry":{"type":"Point","coordinates":[-42.5,%f]},"properties":{"waterway":"waterfall","name":"Falls %d"}}`,
			base+int64(n), lat, n)
	}
	file := strings.Join([]string{
		falls(1, -61.5),
		falls(2, -61.6),
		fmt.Sprintf(`{"type":"Feature","id":"n%d","geometry":{"type":"Point","coordinates":[-42.5,%f]},"properties":{"tourism":"viewpoint"}}`,
			base+3, -61.6+100*deg),
	}, "\n") + "\n"
	stats, err := importPlaces(ctx, tx, slog.New(slog.DiscardHandler), strings.NewReader(file), false, 1)
	if err != nil || stats.Imported != 2 || stats.NearViewpoint != 1 {
		t.Fatalf("import: %+v, %v; want the viewpoint and one waterfall imported, one left out", stats, err)
	}
	var radius float64
	if err := tx.QueryRow(ctx, `SELECT sqrt(ST_Area(geom::geography) / pi()) FROM spots
		WHERE osm_type = 'node' AND osm_id = $1 AND category = 'waterfall'`, base+1).Scan(&radius); err != nil {
		t.Fatalf("the waterfall far from a viewpoint: %v", err)
	}
	if radius < 74 || radius > 76 {
		t.Errorf("waterfall circle radius %.1f m, want 75", radius)
	}
	var near int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM spots WHERE osm_type = 'node' AND osm_id = $1`, base+2).Scan(&near); err != nil || near != 0 {
		t.Errorf("the waterfall near a viewpoint: %d rows (%v), want none", near, err)
	}
}
