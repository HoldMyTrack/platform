package stats

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/HoldMyTrack/platform/services/server/internal/db"
	"github.com/HoldMyTrack/platform/services/server/internal/httpapi"
)

// testTx is a REPEATABLE READ transaction on TEST_DATABASE_URL, rolled back when the test ends
// (skipped without one; docs/DEVELOPMENT.md). Other packages' tests share the database, so the
// test reads each value before and after seeding, in one snapshot, and checks the difference.
func testTx(t *testing.T) pgx.Tx {
	t.Helper()
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	pool, err := db.Open(ctx, url, 0)
	if err != nil {
		t.Fatalf("open test database: %v", err)
	}
	t.Cleanup(pool.Close)
	if err := db.Migrate(ctx, pool); err != nil {
		t.Fatalf("migrate test database: %v", err)
	}
	tx, err := pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead})
	if err != nil {
		t.Fatalf("begin: %v", err)
	}
	t.Cleanup(func() { tx.Rollback(context.Background()) })
	return tx
}

func TestDemoUserID(t *testing.T) {
	if demoUserID != httpapi.DemoCustomerUserID {
		t.Fatalf("demoUserID %s, httpapi.DemoCustomerUserID %s", demoUserID, httpapi.DemoCustomerUserID)
	}
}

func TestTake(t *testing.T) {
	tx := testTx(t)
	ctx := context.Background()
	day := time.Date(2001, 2, 3, 0, 0, 0, 0, time.UTC)
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := tx.Exec(ctx, q, args...); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}

	before, err := compute(ctx, tx, day)
	if err != nil {
		t.Fatal(err)
	}

	n := 0
	account := func(country string, lastSeen *time.Time, created time.Time) string {
		t.Helper()
		n++
		var id string
		if err := tx.QueryRow(ctx, `
			INSERT INTO users (email, country, last_seen_at, created_at) VALUES ($1, $2, $3, $4) RETURNING id`,
			fmt.Sprintf("stats-test-%d-%d@holdmytrack.invalid", time.Now().UnixNano(), n), country, lastSeen, created,
		).Scan(&id); err != nil {
			t.Fatalf("create account: %v", err)
		}
		return id
	}
	at := func(d time.Duration) *time.Time { v := day.Add(d); return &v }
	track := func(userID, source string, created time.Time) string {
		t.Helper()
		var id string
		if err := tx.QueryRow(ctx, `
			INSERT INTO tracks (user_id, source, track_type, started_at, timezone, created_at)
			VALUES ($1, $2, 'run', $3, 'UTC', $3) RETURNING id`, userID, source, created,
		).Scan(&id); err != nil {
			t.Fatalf("create track: %v", err)
		}
		return id
	}

	// Five accounts in QQ, four in QZ and one in QY: QQ keeps its key, QZ and QY fold into an
	// other of five. QQ's last visits fall on the day, six days before it, seven days before it,
	// and never.
	var qq []string
	for i, seen := range []*time.Time{at(time.Hour), at(-6 * 24 * time.Hour), at(-7 * 24 * time.Hour), nil, nil} {
		created := day.Add(-48 * time.Hour)
		if i == 0 {
			created = day.Add(2 * time.Hour) // a signup on the day
		}
		qq = append(qq, account("QQ", seen, created))
	}
	var qz []string
	for range 4 {
		qz = append(qz, account("QZ", nil, day.Add(-48*time.Hour)))
	}
	account("QY", nil, day.Add(-48*time.Hour))
	deleted := account("QQ", at(time.Hour), day.Add(-48*time.Hour))
	exec(`UPDATE users SET deleted_at = NOW() WHERE id = $1`, deleted)

	var qqCountry, qzCountry, qyCountry int
	for code, id := range map[string]*int{"QQ": &qqCountry, "QZ": &qzCountry, "QY": &qyCountry} {
		if err := tx.QueryRow(ctx, `
			INSERT INTO admin_countries (code, name, geom) VALUES ($1, $1, ST_Multi(ST_MakeEnvelope(0, 0, 1, 1, 4326)))
			RETURNING id`, code).Scan(id); err != nil {
			t.Fatalf("create country: %v", err)
		}
	}

	// Tracks: three of one account's on the day (two uploads, one sync), one each for two
	// more accounts the day before; the demo's and the deleted account's count nowhere.
	a1 := track(qq[0], "upload", day.Add(3*time.Hour))
	track(qq[0], "upload", day.Add(4*time.Hour))
	track(qq[0], "healthconnect", day.Add(5*time.Hour))
	a2 := track(qq[1], "recorded", day.Add(-time.Hour))
	a3 := track(qz[0], "upload", day.Add(-time.Hour))
	a4 := track(qq[2], "recorded", day.Add(-time.Hour))
	a5 := track(qq[3], "recorded", day.Add(-time.Hour))
	track(demoUserID, "upload", day.Add(3*time.Hour))
	track(deleted, "upload", day.Add(3*time.Hour))
	// By the countries their tracks are in: QQ one account, QZ three, QY three. All three
	// fold, into an other of the five distinct accounts behind them; an account counts under
	// each country it was in.
	exec(`INSERT INTO track_country (track_id, country_id) VALUES ($1, $2), ($1, $3)`, a1, qqCountry, qzCountry)
	exec(`INSERT INTO track_country (track_id, country_id) VALUES ($1, $2), ($1, $3)`, a2, qzCountry, qyCountry)
	exec(`INSERT INTO track_country (track_id, country_id) VALUES ($1, $2)`, a3, qyCountry)
	exec(`INSERT INTO track_country (track_id, country_id) VALUES ($1, $2)`, a4, qyCountry)
	exec(`INSERT INTO track_country (track_id, country_id) VALUES ($1, $2)`, a5, qzCountry)

	// Photos: two rows over the same files (a copy) count their bytes once.
	photo := func(userID, trackID, key string, bytes int) {
		exec(`INSERT INTO track_photos (user_id, track_id, route_at, content_type, thumb_content_type, width, height, bytes, image_key)
			VALUES ($1, $2, $3, 'image/jpeg', 'image/jpeg', 10, 10, $4, $5)`, userID, trackID, day, bytes, key)
	}
	photo(qq[0], a1, "stats-test/a", 1000)
	photo(qq[0], a1, "stats-test/a", 1000)
	photo(qq[0], a1, "stats-test/b", 500)

	// Stored objects: two tracks over one original (a split) count it once; one more
	// original isn't measured yet. A Fog tile with its size, one rendered before it was
	// recorded, and a mask.
	exec(`UPDATE tracks SET raw_payload_key = 'stats-test/raw-a', raw_bytes = 2000 WHERE user_id = $1 AND source = 'upload'`, qq[0])
	exec(`UPDATE tracks SET raw_payload_key = 'stats-test/raw-b' WHERE user_id = $1`, qq[1])
	exec(`INSERT INTO fog_tiles (user_id, zoom, tile_x, tile_y, object_key, bytes, dirty)
		VALUES ($1, 14, 1, 1, 'f', 300, false), ($1, 14, 1, 2, 'f', NULL, false)`, qq[0])
	exec(`INSERT INTO track_tile_masks (track_id, zoom, tile_x, tile_y) VALUES ($1, 14, 1, 1)`, a1)
	exec(`INSERT INTO track_tile_mask_data (track_id, zoom, tile_x, tile_y, png) VALUES ($1, 14, 1, 1, $2)`, a1, make([]byte, 50))

	exec(`INSERT INTO r2_ops (day, class, count) VALUES ($1, 'A', 70), ($1, 'B', 900)`, day)

	// Clients: one account on both, one on the web only, one on the Android app 29 days before
	// (still in the 30 days), one on it 30 days before (out of them), one on the iOS app only; the
	// deleted account counts nowhere.
	exec(`UPDATE users SET web_seen_at = $2, android_seen_at = $2, android_build = 9001 WHERE id = $1`, qq[0], at(time.Hour))
	exec(`UPDATE users SET web_seen_at = $2 WHERE id = $1`, qq[1], at(-6*24*time.Hour))
	exec(`UPDATE users SET android_seen_at = $2, android_build = 9000 WHERE id = $1`, qq[2], at(-29*24*time.Hour))
	exec(`UPDATE users SET android_seen_at = $2, android_build = 9000 WHERE id = $1`, qq[3], at(-30*24*time.Hour))
	exec(`UPDATE users SET ios_seen_at = $2, ios_build = 1400 WHERE id = $1`, qq[4], at(time.Hour))
	exec(`UPDATE users SET android_seen_at = $2, android_build = 9001 WHERE id = $1`, deleted, at(time.Hour))

	after, err := compute(ctx, tx, day)
	if err != nil {
		t.Fatal(err)
	}
	for key, want := range map[string]float64{
		"accounts":                        10,
		"signups":                         1,
		"active_1d":                       1,
		"active_7d":                       2,
		"active_30d":                      3,
		"tracks":                          7,
		"tracks_added":                    3,
		"tracks_by_source.upload":         3,
		"tracks_by_source.healthconnect":  1,
		"tracks_by_source.recorded":       3,
		"tracks_by_source.healthkit":      0,
		"tracks_added_by_source.upload":   2,
		"photos":                          3,
		"storage_bytes.photos":            1500,
		"accounts_by_country.qq":          5,
		"accounts_by_country.qz":          0,
		"accounts_by_country.other":       5,
		"accounts_with.photos":            1,
		"track_accounts_by_country.qq":    0, // one account: folded
		"track_accounts_by_country.other": 7,
		"tracks_by_country.other":         7,
		"storage_bytes.originals":         2000,
		"r2_ops.class_a":                  70,
		"r2_ops.class_b":                  900,
		"storage_bytes.fog":               300,
		"storage_bytes_unmeasured_rows":   2, // raw-b, and the second tile
		"clients_30d.both":                1,
		"clients_30d.web_only":            1,
		"clients_30d.android_only":        1,
		"clients_30d.ios_only":            1,
		"ios_builds_30d.1400":             1,
		"android_builds_30d.9001":         1,
		"android_builds_30d.9000":         1,
	} {
		if got := after[key] - before[key]; got != want {
			t.Errorf("%s: went up by %v, want %v", key, got, want)
		}
	}
	if after["original_bytes_per_account.max"] < 2000 {
		t.Errorf("original_bytes_per_account.max %v, want at least the 2000 seeded", after["original_bytes_per_account.max"])
	}
	if got := after["storage_bytes.masks"] - before["storage_bytes.masks"]; got < 50 || got > 60 {
		t.Errorf("storage_bytes.masks went up by %v, want a 50-byte mask's stored size", got)
	}
	if _, ok := after["accounts_by_country.qz"]; ok {
		t.Errorf("accounts_by_country.qz written, want it folded")
	}

	taken, err := Take(ctx, tx, day)
	if err != nil {
		t.Fatal(err)
	}
	if taken != len(after) {
		t.Errorf("Take wrote %d values, want %d", taken, len(after))
	}
	var stored float64
	if err := tx.QueryRow(ctx, `SELECT value FROM daily_stats WHERE day = $1 AND key = 'storage_bytes.photos'`, day).Scan(&stored); err != nil {
		t.Fatal(err)
	}
	if stored != after["storage_bytes.photos"] {
		t.Errorf("stored storage_bytes.photos %v, want %v", stored, after["storage_bytes.photos"])
	}

	// Again for the same day: nothing changes.
	exec(`UPDATE tracks SET source = 'healthkit' WHERE user_id = $1`, qq[0])
	if again, err := Take(ctx, tx, day); err != nil || again != 0 {
		t.Errorf("second Take: wrote %d, err %v; want 0, nil", again, err)
	}
	if err := tx.QueryRow(ctx, `SELECT value FROM daily_stats WHERE day = $1 AND key = 'storage_bytes.photos'`, day).Scan(&stored); err != nil {
		t.Fatal(err)
	}
	if stored != after["storage_bytes.photos"] {
		t.Errorf("after a second Take, storage_bytes.photos %v, want %v", stored, after["storage_bytes.photos"])
	}
}

func TestTakeCountsVisitorsAndDeletesTheirHashes(t *testing.T) {
	tx := testTx(t)
	ctx := context.Background()
	day := time.Date(2001, 3, 4, 0, 0, 0, 0, time.UTC)
	next := day.AddDate(0, 0, 1)
	for _, q := range []string{
		`INSERT INTO visitor_salts (day, salt) VALUES ('2001-03-03', 'a'), ('2001-03-04', 'b'), ('2001-03-05', 'c')`,
		`INSERT INTO visitor_days (day, hash) VALUES ('2001-03-03', 'x'), ('2001-03-04', 'x'), ('2001-03-04', 'y'), ('2001-03-05', 'z')`,
	} {
		if _, err := tx.Exec(ctx, q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	if _, err := Take(ctx, tx, day); err != nil {
		t.Fatalf("take: %v", err)
	}
	var visitors float64
	if err := tx.QueryRow(ctx, `SELECT value FROM daily_stats WHERE day = $1 AND key = 'visitors'`, day).Scan(&visitors); err != nil {
		t.Fatalf("read visitors: %v", err)
	}
	if visitors != 2 {
		t.Errorf("visitors = %v, want 2", visitors)
	}
	var hashes, salts int
	if err := tx.QueryRow(ctx, `SELECT (SELECT count(*) FROM visitor_days WHERE day <= $1), (SELECT count(*) FROM visitor_salts WHERE day <= $1)`, day).Scan(&hashes, &salts); err != nil {
		t.Fatalf("count left: %v", err)
	}
	if hashes != 0 || salts != 0 {
		t.Errorf("left %d hashes and %d salts on or before the day, want none", hashes, salts)
	}
	if err := tx.QueryRow(ctx, `SELECT (SELECT count(*) FROM visitor_days WHERE day = $1), (SELECT count(*) FROM visitor_salts WHERE day = $1)`, next).Scan(&hashes, &salts); err != nil {
		t.Fatalf("count next: %v", err)
	}
	if hashes != 1 || salts != 1 {
		t.Errorf("the next day has %d hashes and %d salts, want it untouched", hashes, salts)
	}
}
