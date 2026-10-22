package db

import (
	"context"
	"fmt"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// scratchDatabase creates an empty database for one test and drops it afterwards; it reads
// TEST_DATABASE_URL and skips without it.
func scratchDatabase(t *testing.T) *pgxpool.Config {
	t.Helper()
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	admin, err := Open(ctx, url)
	if err != nil {
		t.Fatalf("open test database: %v", err)
	}
	t.Cleanup(admin.Close)

	name := fmt.Sprintf("holdmytrack_migrate_%d", time.Now().UnixNano())
	if _, err := admin.Exec(ctx, `CREATE DATABASE `+pgx.Identifier{name}.Sanitize()); err != nil {
		t.Fatalf("create database: %v", err)
	}
	t.Cleanup(func() {
		if _, err := admin.Exec(context.Background(), `DROP DATABASE `+pgx.Identifier{name}.Sanitize()+` WITH (FORCE)`); err != nil {
			t.Errorf("drop database: %v", err)
		}
	})
	cfg, err := pgxpool.ParseConfig(url)
	if err != nil {
		t.Fatalf("parse url: %v", err)
	}
	cfg.ConnConfig.Database = name
	return cfg
}

// Several Migrate calls at once on an empty database all succeed, each migration applied
// once: the advisory lock makes them take turns.
func TestMigrateConcurrent(t *testing.T) {
	ctx := context.Background()
	cfg := scratchDatabase(t)

	const callers = 4
	errs := make([]error, callers)
	var wg sync.WaitGroup
	for i := range callers {
		pool, err := pgxpool.NewWithConfig(ctx, cfg)
		if err != nil {
			t.Fatalf("open %s: %v", cfg.ConnConfig.Database, err)
		}
		t.Cleanup(pool.Close)
		wg.Add(1)
		go func() {
			defer wg.Done()
			errs[i] = Migrate(ctx, pool)
		}()
	}
	wg.Wait()
	for i, err := range errs {
		if err != nil {
			t.Errorf("caller %d: %v", i, err)
		}
	}
}

// A database the replaced migrations built gets the baseline recorded, not run.
func TestMigrateRecordsTheBaselineOverItsMigrations(t *testing.T) {
	ctx := context.Background()
	pool, err := pgxpool.NewWithConfig(ctx, scratchDatabase(t))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	for _, q := range []string{
		`CREATE TABLE schema_migrations (filename TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW())`,
		`INSERT INTO schema_migrations (filename) VALUES ('0001_users_and_auth.sql'), ('` + baselineCovers + `')`,
	} {
		if _, err := pool.Exec(ctx, q); err != nil {
			t.Fatal(err)
		}
	}
	if err := Migrate(ctx, pool); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	var recorded, ran bool
	if err := pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE filename = $1), to_regclass('users') IS NOT NULL`, baselineFile).Scan(&recorded, &ran); err != nil {
		t.Fatal(err)
	}
	if !recorded || ran {
		t.Errorf("baseline recorded %v, ran %v; want recorded and not run", recorded, ran)
	}
}
