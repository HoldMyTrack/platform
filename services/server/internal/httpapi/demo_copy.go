package httpapi

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/HoldMyTrack/platform/services/server/internal/storage"
)

// demoCopyAccount is what SeedDemoCopy needs to know about the account it would fill.
type demoCopyAccount struct {
	isDemo       bool
	verified     bool
	tracks       int
	privacyZones int
}

// demoCopyRefusal says why an account can't take a copy of the Demo Customer's history, or
// nil when it can. Only a verified account with no tracks and no Private locations qualifies:
// the copy must never mix into someone's own data, and an unverified account is deleted
// within days (worker/unverified_accounts.go).
func demoCopyRefusal(a demoCopyAccount) error {
	switch {
	case a.isDemo:
		return errors.New("that is the Demo Customer itself")
	case !a.verified:
		return errors.New("the account's email isn't verified yet")
	case a.tracks > 0:
		return fmt.Errorf("the account already has %d tracks", a.tracks)
	case a.privacyZones > 0:
		return fmt.Errorf("the account already has %d Private locations", a.privacyZones)
	}
	return nil
}

// SeedDemoCopy fills the account with email with the Demo Customer's history, for an account
// someone else signs in to, such as App Review's (the `seed-demo-copy` CLI subcommand). The
// Demo Customer's Private locations live only in the database, so they are copied first: they
// are applied at ingest, before any track is stored. Then demo_data/ goes in as for the demo
// itself (seedDemoAccount), so the copy is the repository's history, not the demo's rows.
func SeedDemoCopy(ctx context.Context, pool *pgxpool.Pool, store *storage.Store, log *slog.Logger, rawEmail string) error {
	email, err := normalizeEmail(rawEmail)
	if err != nil {
		return err
	}
	var userID string
	var a demoCopyAccount
	err = pool.QueryRow(ctx, `
		SELECT u.id, u.id = $2, u.email_verified,
			(SELECT count(*) FROM tracks t WHERE t.user_id = u.id),
			(SELECT count(*) FROM privacy_zones z WHERE z.user_id = u.id)
		FROM users u WHERE u.email = $1 AND u.deleted_at IS NULL`, email, DemoCustomerUserID,
	).Scan(&userID, &a.isDemo, &a.verified, &a.tracks, &a.privacyZones)
	if errors.Is(err, pgx.ErrNoRows) {
		return fmt.Errorf("seed demo copy: no account with email %q", email)
	}
	if err != nil {
		return fmt.Errorf("seed demo copy: %w", err)
	}
	if err := demoCopyRefusal(a); err != nil {
		return fmt.Errorf("seed demo copy: %s: %w", email, err)
	}

	fsys, err := fs.Sub(demoData, "demo_data")
	if err != nil {
		return fmt.Errorf("seed demo copy: %w", err)
	}
	names, err := demoFiles(fsys)
	if err != nil {
		return fmt.Errorf("seed demo copy: %w", err)
	}
	manifest, err := loadDemoManifest(fsys, names)
	if err != nil {
		return fmt.Errorf("seed demo copy: %w", err)
	}

	tag, err := pool.Exec(ctx, `
		INSERT INTO privacy_zones (user_id, center, radius_m, name)
		SELECT $1, center, radius_m, name FROM privacy_zones WHERE user_id = $2`,
		userID, DemoCustomerUserID)
	if err != nil {
		return fmt.Errorf("seed demo copy: private locations: %w", err)
	}
	log.Info("seed demo copy: private locations copied", "user_id", userID, "count", tag.RowsAffected())

	if err := seedDemoAccount(ctx, pool, store, log, fsys, names, manifest, userID); err != nil {
		return fmt.Errorf("seed demo copy: %w", err)
	}
	return nil
}
