package worker

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/HoldMyTrack/platform/services/server/internal/db"
)

// unverifiedAccountTTL is how long an account that has never confirmed its email is kept
// (docs/SPEC.md FR-1.8). Such an account holds nothing but its address, and keeping it keeps a
// mistyped or someone else's address and blocks its owner's signup.
const unverifiedAccountTTL = 7 * 24 * time.Hour

// demoUserID is the shared demo account (httpapi.DemoCustomerUserID, which a test holds this
// equal to): it is stored unverified and never gated.
const demoUserID = "22222222-2222-2222-2222-222222222222"

// closeUnverifiedAccounts closes (db.CloseAccounts) every account never verified within
// unverifiedAccountTTL of its signup, for purgeDeletedAccounts to remove. An account with a
// verification row still live waits for it, so a resend or a corrected address late in the week
// still works. email_verified only ever turns true, so a verified account changing its address is
// never taken. SKIP LOCKED leaves an account a verification holds for the next day.
func closeUnverifiedAccounts(ctx context.Context, pool *pgxpool.Pool, log *slog.Logger) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("unverified accounts: begin: %w", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck // no-op once committed

	rows, err := tx.Query(ctx, `
		SELECT id FROM users u
		WHERE NOT email_verified AND deleted_at IS NULL AND id <> $1
		  AND created_at < NOW() - make_interval(secs => $2)
		  AND NOT EXISTS (SELECT 1 FROM email_verifications ev WHERE ev.user_id = u.id AND ev.expires_at > NOW())
		FOR UPDATE SKIP LOCKED
	`, demoUserID, unverifiedAccountTTL.Seconds())
	if err != nil {
		return fmt.Errorf("unverified accounts: query: %w", err)
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return fmt.Errorf("unverified accounts: query: %w", err)
	}
	if len(ids) == 0 {
		return nil
	}
	if err := db.CloseAccounts(ctx, tx, ids); err != nil {
		return fmt.Errorf("unverified accounts: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("unverified accounts: commit: %w", err)
	}
	log.Info("unverified accounts closed for deletion", "accounts", len(ids))
	return nil
}
