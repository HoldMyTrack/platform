package db

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
)

// CloseAccounts takes away every way back into the accounts (sessions, Google, Facebook and
// Apple identities, reset, verification and app sign-in tokens, the password), renames each
// email to a placeholder so the address can sign up again at once, and stamps deleted_at, for
// the worker's account purge to remove the rest (IMPLEMENTATION.md §4.28). It runs in the
// caller's transaction: account deletion and the worker's unverified-account sweep both close
// accounts through it, so a new way back in is added here once.
func CloseAccounts(ctx context.Context, tx pgx.Tx, ids []string) error {
	for _, q := range []string{
		`DELETE FROM sessions WHERE user_id = ANY($1::uuid[])`,
		`DELETE FROM user_identities WHERE user_id = ANY($1::uuid[])`,
		`DELETE FROM password_resets WHERE user_id = ANY($1::uuid[])`,
		`DELETE FROM email_verifications WHERE user_id = ANY($1::uuid[])`,
		`DELETE FROM auth_handoffs WHERE user_id = ANY($1::uuid[])`,
		`UPDATE users SET email = 'deleted-' || id || '@holdmytrack.invalid', password_hash = NULL, deleted_at = NOW() WHERE id = ANY($1::uuid[])`,
	} {
		if _, err := tx.Exec(ctx, q, ids); err != nil {
			return fmt.Errorf("close accounts: %w", err)
		}
	}
	return nil
}
