// Package db owns the Postgres pool and a small embedded migration runner: what a migration
// library does, reading embedded SQL files in order and skipping the applied ones, fits in a page
// here (services/server/README.md). The runner also knows the baseline, which replaced the first
// 45 migrations: a database they built records it without running it.
package db

import (
	"context"
	"fmt"
	"io/fs"
	"sort"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/HoldMyTrack/platform/services/server/migrations"
)

var migrationsFS = migrations.FS

func Open(ctx context.Context, databaseURL string) (*pgxpool.Pool, error) {
	return OpenSized(ctx, databaseURL, 0)
}

// OpenSized is Open with the pool capped at maxConns connections; 0 keeps pgx's default
// (the greater of 4 and the CPU count), which is too few for `work` running several jobs at
// once, each rendering many tiles side by side.
func OpenSized(ctx context.Context, databaseURL string, maxConns int32) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		return nil, fmt.Errorf("db: parse url: %w", err)
	}
	if maxConns > 0 {
		cfg.MaxConns = maxConns
	}
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("db: open pool: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("db: ping: %w", err)
	}
	return pool, nil
}

// migrateLockKey is the advisory lock Migrate holds while it runs. Any fixed number works;
// it only has to be the same in every caller.
const migrateLockKey = 0x486d7400 // "Hmt\0"

// Migrate applies every embedded migration not yet recorded in schema_migrations, in
// filename order, each in its own transaction. It holds an advisory lock throughout, so
// two callers at once (go test runs each package's database tests in its own process) take
// turns: the second waits, then finds the first's migrations recorded and skips them.
func Migrate(ctx context.Context, pool *pgxpool.Pool) error {
	// A session lock belongs to one connection, so the whole run uses this one.
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return fmt.Errorf("db: acquire connection: %w", err)
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx, `SELECT pg_advisory_lock($1)`, migrateLockKey); err != nil {
		return fmt.Errorf("db: take migration lock: %w", err)
	}
	defer func() {
		// The connection goes back to the pool, so the lock mustn't go with it; if
		// releasing fails, close the connection, which ends the lock with its session.
		if _, err := conn.Exec(context.Background(), `SELECT pg_advisory_unlock($1)`, migrateLockKey); err != nil {
			conn.Conn().Close(context.Background())
		}
	}()

	if _, err := conn.Exec(ctx, `
		CREATE TABLE IF NOT EXISTS schema_migrations (
			filename    TEXT PRIMARY KEY,
			applied_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`); err != nil {
		return fmt.Errorf("db: create schema_migrations: %w", err)
	}

	entries, err := fs.ReadDir(migrationsFS, ".")
	if err != nil {
		return fmt.Errorf("db: read embedded migrations: %w", err)
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if !e.IsDir() {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names) // 0001_..., 0002_..., ... — filename order is application order.

	recorded, err := recordedMigrations(ctx, conn)
	if err != nil {
		return err
	}
	switch baselineStep(recorded) {
	case baselineRecord:
		if _, err := conn.Exec(ctx, `INSERT INTO schema_migrations (filename) VALUES ($1)`, baselineFile); err != nil {
			return fmt.Errorf("db: record %s: %w", baselineFile, err)
		}
		recorded[baselineFile] = true
	case baselineRefuse:
		return fmt.Errorf("db: the database stopped partway through the migrations %s replaced; migrate it with a build from before %s first", baselineFile, baselineFile)
	}

	for _, name := range names {
		if recorded[name] {
			continue
		}

		sqlBytes, err := migrationsFS.ReadFile(name)
		if err != nil {
			return fmt.Errorf("db: read %s: %w", name, err)
		}

		tx, err := conn.Begin(ctx)
		if err != nil {
			return fmt.Errorf("db: begin tx for %s: %w", name, err)
		}
		if _, err := tx.Exec(ctx, string(sqlBytes)); err != nil {
			tx.Rollback(ctx)
			return fmt.Errorf("db: apply %s: %w", name, err)
		}
		if _, err := tx.Exec(ctx,
			`INSERT INTO schema_migrations (filename) VALUES ($1)`, name,
		); err != nil {
			tx.Rollback(ctx)
			return fmt.Errorf("db: record %s: %w", name, err)
		}
		if err := tx.Commit(ctx); err != nil {
			return fmt.Errorf("db: commit %s: %w", name, err)
		}
	}
	return nil
}

// baselineFile holds the schema the migrations up to baselineCovers built, which it replaced.
const (
	baselineFile   = "0045_baseline.sql"
	baselineCovers = "0045_activity_pending_index.sql"
)

type baselineAction int

const (
	baselineRun    baselineAction = iota // a new database, or one that has it already
	baselineRecord                       // the schema exists: mark the baseline applied
	baselineRefuse                       // part of the replaced migrations: no file can finish them
)

// baselineStep says what Migrate does about the baseline, given the filenames a database has
// recorded.
func baselineStep(recorded map[string]bool) baselineAction {
	switch {
	case recorded[baselineFile] || len(recorded) == 0:
		return baselineRun
	case recorded[baselineCovers]:
		return baselineRecord
	default:
		return baselineRefuse
	}
}

func recordedMigrations(ctx context.Context, conn *pgxpool.Conn) (map[string]bool, error) {
	rows, err := conn.Query(ctx, `SELECT filename FROM schema_migrations`)
	if err != nil {
		return nil, fmt.Errorf("db: read schema_migrations: %w", err)
	}
	names, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return nil, fmt.Errorf("db: read schema_migrations: %w", err)
	}
	recorded := make(map[string]bool, len(names))
	for _, n := range names {
		recorded[n] = true
	}
	return recorded, nil
}
