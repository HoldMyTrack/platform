package httpapi

// Covers docs/SPEC.md FR-1.9 and FR-1.14: the account a provider that vouches for the email
// signs in to (resolveVerifiedUser).

import (
	"context"
	"fmt"
	"testing"
	"time"
)

func TestResolveVerifiedUser(t *testing.T) {
	d := newDBTest(t)
	ctx := context.Background()
	unique := func(prefix string) string { return fmt.Sprintf("%s-%d", prefix, time.Now().UnixNano()) }
	cleanup := func(email string) {
		t.Cleanup(func() {
			if _, err := d.pool.Exec(context.Background(), `DELETE FROM users WHERE email = $1`, email); err != nil {
				t.Errorf("delete account: %v", err)
			}
		})
	}
	newUser := func(verified bool) (id, email string) {
		email = unique("verified") + "@holdmytrack.invalid"
		cleanup(email)
		if err := d.pool.QueryRow(ctx, `
			INSERT INTO users (email, email_verified, password_hash) VALUES ($1, $2, 'hash') RETURNING id
		`, email, verified).Scan(&id); err != nil {
			t.Fatal(err)
		}
		return id, email
	}
	count := func(q string, args ...any) int {
		var n int
		if err := d.pool.QueryRow(ctx, q, args...).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}

	t.Run("a new email makes a verified account", func(t *testing.T) {
		email := unique("new") + "@holdmytrack.invalid"
		cleanup(email)
		id, err := d.srv.resolveVerifiedUser(ctx, "apple", unique("sub"), email, "Some One", "Europe/Berlin")
		if err != nil {
			t.Fatal(err)
		}
		var verified bool
		var name, tz string
		if err := d.pool.QueryRow(ctx, `SELECT email_verified, display_name, timezone FROM users WHERE id = $1`, id).Scan(&verified, &name, &tz); err != nil {
			t.Fatal(err)
		}
		if !verified || name != "Some One" || tz != "Europe/Berlin" {
			t.Fatalf("got verified %v, name %q, tz %q", verified, name, tz)
		}
	})

	t.Run("the linked subject signs in whatever the email is now", func(t *testing.T) {
		id, email := newUser(true)
		sub := unique("sub")
		if _, err := d.srv.resolveVerifiedUser(ctx, "apple", sub, email, "", ""); err != nil {
			t.Fatal(err)
		}
		got, err := d.srv.resolveVerifiedUser(ctx, "apple", sub, "changed@holdmytrack.invalid", "", "")
		if err != nil || got != id {
			t.Fatalf("got %q, %v; want %q", got, err, id)
		}
	})

	t.Run("a verified account with the email is linked and keeps its password", func(t *testing.T) {
		id, email := newUser(true)
		got, err := d.srv.resolveVerifiedUser(ctx, "apple", unique("sub"), email, "", "")
		if err != nil || got != id {
			t.Fatalf("got %q, %v; want %q", got, err, id)
		}
		if count(`SELECT count(*) FROM users WHERE id = $1 AND password_hash IS NOT NULL`, id) != 1 {
			t.Fatal("password cleared")
		}
	})

	t.Run("an unverified account loses what its maker set", func(t *testing.T) {
		id, email := newUser(false)
		if _, err := d.pool.Exec(ctx, `INSERT INTO user_identities (user_id, provider, subject) VALUES ($1, 'facebook', $2)`, id, unique("fb")); err != nil {
			t.Fatal(err)
		}
		if _, err := d.pool.Exec(ctx, `INSERT INTO sessions (user_id, expires_at) VALUES ($1, NOW() + INTERVAL '1 hour')`, id); err != nil {
			t.Fatal(err)
		}
		if _, err := d.srv.resolveVerifiedUser(ctx, "apple", unique("sub"), email, "", ""); err != nil {
			t.Fatal(err)
		}
		if count(`SELECT count(*) FROM users WHERE id = $1 AND email_verified AND password_hash IS NULL`, id) != 1 {
			t.Fatal("not verified, or the password kept")
		}
		if n := count(`SELECT count(*) FROM user_identities WHERE user_id = $1 AND provider <> 'apple'`, id); n != 0 {
			t.Fatalf("%d other identities kept", n)
		}
		if n := count(`SELECT count(*) FROM sessions WHERE user_id = $1`, id); n != 0 {
			t.Fatalf("%d sessions kept", n)
		}
	})

	t.Run("an account linked to another subject is refused", func(t *testing.T) {
		_, email := newUser(true)
		if _, err := d.srv.resolveVerifiedUser(ctx, "apple", unique("sub"), email, "", ""); err != nil {
			t.Fatal(err)
		}
		if _, err := d.srv.resolveVerifiedUser(ctx, "apple", unique("other"), email, "", ""); err == nil {
			t.Fatal("relinked")
		}
	})

	t.Run("the demo account is never linked", func(t *testing.T) {
		var demoEmail string
		if err := d.pool.QueryRow(ctx, `SELECT email FROM users WHERE id = $1`, DemoCustomerUserID).Scan(&demoEmail); err != nil {
			t.Fatal(err)
		}
		if _, err := d.srv.resolveVerifiedUser(ctx, "apple", unique("sub"), demoEmail, "", ""); err == nil {
			t.Fatal("signed in to the demo account")
		}
	})
}
