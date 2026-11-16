package worker

import (
	"context"
	"fmt"
	"log/slog"
	"testing"
	"time"

	"github.com/HoldMyTrack/platform/services/server/internal/httpapi"
)

func TestDemoUserID(t *testing.T) {
	if demoUserID != httpapi.DemoCustomerUserID {
		t.Fatalf("demoUserID %s, httpapi.DemoCustomerUserID %s", demoUserID, httpapi.DemoCustomerUserID)
	}
}

// Only an account never verified, past unverifiedAccountTTL and with no live link is closed,
// and its ways back in go.
func TestCloseUnverifiedAccounts(t *testing.T) {
	pool, _ := testPool(t)
	ctx := context.Background()
	account := func(verified bool, age, linkExpiry string) string {
		t.Helper()
		var id string
		email := fmt.Sprintf("unverified-test-%d@holdmytrack.invalid", time.Now().UnixNano())
		if err := pool.QueryRow(ctx,
			`INSERT INTO users (email, email_verified, created_at) VALUES ($1, $2, NOW() - $3::interval) RETURNING id`,
			email, verified, age,
		).Scan(&id); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { pool.Exec(context.Background(), `DELETE FROM users WHERE id = $1`, id) })
		if _, err := pool.Exec(ctx, `INSERT INTO sessions (user_id, token_hash, expires_at) VALUES ($1, gen_random_uuid()::text::bytea, NOW() + interval '1 day')`, id); err != nil {
			t.Fatal(err)
		}
		if _, err := pool.Exec(ctx, `INSERT INTO email_verifications (user_id, token_hash, expires_at, email) VALUES ($1, gen_random_uuid()::text::bytea, NOW() + $2::interval, 'x@example.invalid')`, id, linkExpiry); err != nil {
			t.Fatal(err)
		}
		return id
	}
	stale := account(false, "8 days", "-1 hour")
	fresh := account(false, "6 days", "-1 hour")
	resent := account(false, "8 days", "1 hour")
	verified := account(true, "30 days", "-1 hour")

	if err := closeUnverifiedAccounts(ctx, pool, slog.New(slog.DiscardHandler)); err != nil {
		t.Fatal(err)
	}
	for id, wantClosed := range map[string]bool{stale: true, fresh: false, resent: false, verified: false, demoUserID: false} {
		var closed, signIns bool
		if err := pool.QueryRow(ctx, `
			SELECT deleted_at IS NOT NULL AND email LIKE 'deleted-%' AND password_hash IS NULL,
			       EXISTS (SELECT 1 FROM sessions WHERE user_id = $1) OR EXISTS (SELECT 1 FROM email_verifications WHERE user_id = $1)
			FROM users WHERE id = $1`, id).Scan(&closed, &signIns); err != nil {
			t.Fatal(err)
		}
		if closed != wantClosed {
			t.Errorf("%s: closed %v, want %v", id, closed, wantClosed)
		}
		if id != demoUserID && signIns == wantClosed {
			t.Errorf("%s: sessions or links left %v, want %v", id, signIns, !wantClosed)
		}
	}
}
