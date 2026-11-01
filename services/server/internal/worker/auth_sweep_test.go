package worker

import (
	"context"
	"log/slog"
	"testing"
)

// Expired sessions and links go; live ones stay.
func TestSweepExpiredAuthKeepsLiveRows(t *testing.T) {
	pool, userID := testPool(t)
	ctx := context.Background()
	insert := map[string]string{
		"sessions":            `INSERT INTO sessions (user_id, token_hash, expires_at) VALUES ($1, gen_random_uuid()::text::bytea, NOW() + $2::interval)`,
		"password_resets":     `INSERT INTO password_resets (user_id, token_hash, expires_at) VALUES ($1, gen_random_uuid()::text::bytea, NOW() + $2::interval)`,
		"email_verifications": `INSERT INTO email_verifications (user_id, token_hash, expires_at, email) VALUES ($1, gen_random_uuid()::text::bytea, NOW() + $2::interval, 'typo@example.invalid')`,
	}
	for table, q := range insert {
		for _, in := range []string{"-1 hour", "1 hour"} {
			if _, err := pool.Exec(ctx, q, userID, in); err != nil {
				t.Fatalf("%s: %v", table, err)
			}
		}
	}

	if err := sweepExpiredAuth(ctx, pool, slog.New(slog.DiscardHandler)); err != nil {
		t.Fatal(err)
	}
	for table := range insert {
		var expired, live int
		if err := pool.QueryRow(ctx, `SELECT count(*) FILTER (WHERE expires_at < NOW()), count(*) FILTER (WHERE expires_at >= NOW()) FROM `+table+` WHERE user_id = $1`, userID).Scan(&expired, &live); err != nil {
			t.Fatal(err)
		}
		if expired != 0 || live != 1 {
			t.Errorf("%s: %d expired, %d live left; want 0 and 1", table, expired, live)
		}
	}
}
