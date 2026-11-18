package db

import (
	"context"
	"io/fs"
	"sort"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
)

// No table, column, index or constraint keeps a name from before Tracks and Trips.
func TestSchemaHasNoOldNames(t *testing.T) {
	ctx := context.Background()
	pool, err := pgxpool.NewWithConfig(ctx, scratchDatabase(t))
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	if err := Migrate(ctx, pool); err != nil {
		t.Fatal(err)
	}
	rows, err := pool.Query(ctx, `
		SELECT 'relation ' || relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
		 WHERE n.nspname = 'public' AND relname ~ '(activit|stor(y|ies))'
		UNION ALL
		SELECT 'column ' || table_name || '.' || column_name FROM information_schema.columns
		 WHERE table_schema = 'public' AND column_name ~ '(activit|stor(y|ies)|track_edit)'
		UNION ALL
		SELECT 'constraint ' || conname FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace
		 WHERE n.nspname = 'public' AND conname ~ '(activit|stor(y|ies))'`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			t.Fatal(err)
		}
		t.Errorf("old name: %s", name)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
}

// 0057 rewrites what the release before it left: a Trip copy's source, the queue's kinds and
// payload keys, a pending sync's bytes, and a job per stored sync payload.
func TestMigrationRenamesStoredValues(t *testing.T) {
	ctx := context.Background()
	pool, err := pgxpool.NewWithConfig(ctx, scratchDatabase(t))
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()

	// Every migration before 0057, recorded as Migrate records them.
	entries, err := fs.ReadDir(migrationsFS, ".")
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".sql") && e.Name() < "0057" {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	if _, err := pool.Exec(ctx, `CREATE TABLE schema_migrations (filename TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW())`); err != nil {
		t.Fatal(err)
	}
	for _, name := range names {
		sql, err := migrationsFS.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := pool.Exec(ctx, string(sql)); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if _, err := pool.Exec(ctx, `INSERT INTO schema_migrations (filename) VALUES ($1)`, name); err != nil {
			t.Fatal(err)
		}
	}

	if _, err := pool.Exec(ctx, `
		INSERT INTO users (id, email, password_hash, email_verified) VALUES ('00000000-0000-0000-0000-0000000000a1', 'mig@example.test', 'x', true);
		INSERT INTO activities (id, user_id, source, activity_type, started_at, raw_payload_key, timezone) VALUES
		 ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000a1', 'recorded', 'walking', now(), 'raw/u/recorded/r1.json', 'UTC'),
		 ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000a1', 'story', 'cycling', now(), 'raw/u/story/o1.gpx', 'UTC');
		INSERT INTO jobs (kind, payload, state) VALUES
		 ('edit_track', '{"activity_id":"b1","edit":null}', 'pending'),
		 ('story_copy', '{"story_id":"s1","recipient_id":"r"}', 'done'),
		 ('reprivacy', '{"activity_ids":["b1"]}', 'done');
		INSERT INTO jobs (kind, payload, state, raw) VALUES
		 ('ingest', '{"source":"recorded","raw_payload_key":"raw/u/recorded/r2.json","activity_type":"walking"}', 'pending', convert_to('{"activity_type":"walking","points":[]}', 'UTF8')),
		 ('ingest', '{"source":"upload","raw_payload_key":"raw/u/f.fit"}', 'pending', '\x0e10ff'::bytea);`); err != nil {
		t.Fatal(err)
	}
	if err := Migrate(ctx, pool); err != nil {
		t.Fatal(err)
	}

	var source string
	if err := pool.QueryRow(ctx, `SELECT source FROM tracks WHERE id = '00000000-0000-0000-0000-0000000000b2'`).Scan(&source); err != nil || source != "trip" {
		t.Errorf("Trip copy's source %q, %v; want trip", source, err)
	}
	var lines []string
	rows, err := pool.Query(ctx, `SELECT kind || ' ' || payload::text || ' ' || coalesce(CASE WHEN payload->>'raw_payload_key' LIKE '%.json' THEN convert_from(raw, 'UTF8') ELSE encode(raw, 'hex') END, '') FROM jobs ORDER BY id`)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var line string
		if err := rows.Scan(&line); err != nil {
			t.Fatal(err)
		}
		lines = append(lines, strings.TrimSpace(line))
	}
	rows.Close()
	want := []string{
		`edit_route {"edit": null, "track_id": "b1"}`,
		`trip_copy {"trip_id": "s1", "recipient_id": "r"}`,
		`reprivacy {"track_ids": ["b1"]}`,
		`ingest {"source": "recorded", "track_type": "walking", "raw_payload_key": "raw/u/recorded/r2.json"} {"track_type":"walking","points":[]}`,
		`ingest {"source": "upload", "raw_payload_key": "raw/u/f.fit"} 0e10ff`,
		`rewrite_sync_payload {"key": "raw/u/recorded/r1.json"}`,
	}
	for _, w := range want {
		found := false
		for _, l := range lines {
			if l == w {
				found = true
			}
		}
		if !found {
			t.Errorf("no job %s in\n%s", w, strings.Join(lines, "\n"))
		}
	}
	if len(lines) != len(want) {
		t.Errorf("%d jobs, want %d:\n%s", len(lines), len(want), strings.Join(lines, "\n"))
	}
}
