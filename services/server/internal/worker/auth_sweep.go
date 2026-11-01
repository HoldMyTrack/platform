package worker

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// authSweepInterval is how often sweepExpiredAuth runs. An expired row already stops working
// when it's read; this is about not keeping it.
const authSweepInterval = 24 * time.Hour

// sweepExpiredAuth deletes expired sessions, password-reset links and email-verification links.
// Each refuses itself once past expires_at, but the row would otherwise stay until the account
// is deleted: a verification link keeps the address it was sent to, a mistyped one included
// (docs/DPIA.md).
func sweepExpiredAuth(ctx context.Context, pool *pgxpool.Pool, log *slog.Logger) error {
	total := int64(0)
	for _, table := range []string{"sessions", "password_resets", "email_verifications"} {
		tag, err := pool.Exec(ctx, `DELETE FROM `+table+` WHERE expires_at < NOW()`)
		if err != nil {
			return fmt.Errorf("auth sweep: %s: %w", table, err)
		}
		total += tag.RowsAffected()
	}
	if total > 0 {
		log.Info("expired sign-in rows swept", "rows", total)
	}
	return nil
}
