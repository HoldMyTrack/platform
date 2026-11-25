package httpapi

// Covers docs/SPEC.md FR-1.8 (email verification).

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/bcrypt"
)

// sentMail records what a test's server would have mailed.
type sentMail struct {
	mu                   sync.Mutex
	to, subjects, bodies []string
}

func (m *sentMail) Send(_ context.Context, to, subject, body string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.to = append(m.to, to)
	m.subjects = append(m.subjects, subject)
	m.bodies = append(m.bodies, body)
	return nil
}

func (d *dbTest) email(a account) (email string, verified bool) {
	d.t.Helper()
	if err := d.pool.QueryRow(context.Background(),
		`SELECT email, email_verified FROM users WHERE id = $1`, a.id).Scan(&email, &verified); err != nil {
		d.t.Fatalf("read email: %v", err)
	}
	return email, verified
}

// mailedToken is the token in the newest link to path mailed to an address: the database keeps
// only its hash.
func (d *dbTest) mailedToken(to, path string) string {
	d.t.Helper()
	m := d.srv.mailer.(*sentMail)
	m.mu.Lock()
	defer m.mu.Unlock()
	link := regexp.MustCompile(regexp.QuoteMeta(path) + `\?token=([0-9a-f-]{36})`)
	for i := len(m.bodies) - 1; i >= 0; i-- {
		if found := link.FindStringSubmatch(m.bodies[i]); found != nil && m.to[i] == to {
			return found[1]
		}
	}
	d.t.Fatalf("no %s link mailed to %s", path, to)
	return ""
}

// An email change is the account's only once the new address's owner confirms it: until then
// the account keeps its address and its verified state, and no one else is kept from the
// address.
func TestChangeEmailIsPendingUntilConfirmed(t *testing.T) {
	d := newDBTest(t)
	mails := &sentMail{}
	d.srv.mailer = mails
	a := d.newAccount(false)
	before, _ := d.email(a)
	target := "new-" + before

	d.decode(d.do(a, http.MethodPatch, "/v2/auth/email", map[string]string{"email": target}), http.StatusOK, nil)
	if email, verified := d.email(a); email != before || !verified {
		t.Fatalf("after change: email %q verified %v, want %q still verified", email, verified, before)
	}
	if len(mails.to) != 1 || mails.to[0] != target {
		t.Fatalf("mailed %v, want the new address", mails.to)
	}

	if status, errCode := d.typeCode(a, d.mailedCode(target)); status != http.StatusOK {
		t.Fatalf("typing the new address's code: %d %q, want 200", status, errCode)
	}
	if email, verified := d.email(a); email != target || !verified {
		t.Fatalf("after confirming: email %q verified %v, want %q verified", email, verified, target)
	}
}

// A code sent to the account's address before a change confirms nothing after it: it can't
// mark the new, unproven address verified.
func TestVerificationCodeConfirmsOnlyItsOwnAddress(t *testing.T) {
	d := newDBTest(t)
	d.srv.mailer = &sentMail{}
	a := d.newAccount(false)
	if _, err := d.pool.Exec(context.Background(), `UPDATE users SET email_verified = false WHERE id = $1`, a.id); err != nil {
		t.Fatal(err)
	}
	before, _ := d.email(a)
	if err := d.srv.sendVerificationEmail(context.Background(), a.id, before, "en"); err != nil {
		t.Fatal(err)
	}
	oldCode := d.mailedCode(before)

	d.decode(d.do(a, http.MethodPatch, "/v2/auth/email", map[string]string{"email": "other-" + before}), http.StatusOK, nil)
	if status, _ := d.typeCode(a, oldCode); status != http.StatusBadRequest {
		t.Fatalf("old code: status %d, want 400", status)
	}
	if email, verified := d.email(a); email != before || verified {
		t.Fatalf("email %q verified %v, want %q unverified", email, verified, before)
	}
}

func TestChangeEmailToAnotherAccountsAddressIsRefused(t *testing.T) {
	d := newDBTest(t)
	d.srv.mailer = &sentMail{}
	a, b := d.newAccount(false), d.newAccount(false)
	taken, _ := d.email(b)
	rec := d.do(a, http.MethodPatch, "/v2/auth/email", map[string]string{"email": taken})
	if rec.Code != http.StatusConflict {
		t.Fatalf("status %d, want 409", rec.Code)
	}
}

// After 10 wrong passwords for one email in the window, even the right one is refused: the
// limit is checked before the password is.
func TestSignInFailuresAreLimitedPerEmail(t *testing.T) {
	d := newDBTest(t)
	a := d.newAccount(false)
	email, _ := d.email(a)
	hash, err := bcrypt.GenerateFromPassword([]byte("right-password"), bcrypt.MinCost)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.pool.Exec(context.Background(), `UPDATE users SET password_hash = $2 WHERE id = $1`, a.id, hash); err != nil {
		t.Fatal(err)
	}
	login := func(password string) int {
		return d.do(account{}, http.MethodPost, "/v2/auth/login", map[string]string{"email": email, "password": password}).Code
	}
	if code := login("right-password"); code != http.StatusOK {
		t.Fatalf("first sign-in: %d", code)
	}
	for i := 0; i < 10; i++ {
		if code := login("wrong-password"); code != http.StatusUnauthorized {
			t.Fatalf("wrong password %d: %d, want 401", i+1, code)
		}
	}
	if code := login("right-password"); code != http.StatusTooManyRequests {
		t.Fatalf("right password after 10 failures: %d, want 429", code)
	}
}

// One address trying many accounts' passwords is stopped after 50 failures, even though no
// single email reaches its own limit.
func TestSignInFailuresAreLimitedPerAddress(t *testing.T) {
	d := newDBTest(t)
	login := func(i int) int {
		body := fmt.Sprintf(`{"email":"nobody-%d-%d@holdmytrack.invalid","password":"wrong-password"}`, time.Now().UnixNano(), i)
		req := httptest.NewRequest(http.MethodPost, "/v2/auth/login", strings.NewReader(body))
		req.RemoteAddr = "198.51.100.77:4321"
		rec := serveChecked(t, d.srv.ServeHTTP, req)
		return rec.Code
	}
	for i := 0; i < 50; i++ {
		if code := login(i); code != http.StatusUnauthorized {
			t.Fatalf("attempt %d: %d, want 401", i+1, code)
		}
	}
	if code := login(50); code != http.StatusTooManyRequests {
		t.Fatalf("attempt 51: %d, want 429", code)
	}
}

// blockingMail holds every message until release is closed, counting the ones begun.
type blockingMail struct {
	begun   chan struct{}
	release chan struct{}
}

func (m *blockingMail) Send(context.Context, string, string, string) error {
	m.begun <- struct{}{}
	<-m.release
	return nil
}

// Whether an address has an account changes only what happens after the response is complete:
// the handler returns, and with it the whole answer, while the reset mail is still held.
func TestForgotPasswordAnswersBeforeMailing(t *testing.T) {
	d := newDBTest(t)
	d.srv.afterResponse = func(f func()) { go f() } // as served, not the tests' inline
	a := d.newAccount(false)
	if _, err := d.pool.Exec(context.Background(), `UPDATE users SET password_hash = 'x' WHERE id = $1`, a.id); err != nil {
		t.Fatal(err)
	}
	email, _ := d.email(a)
	mail := &blockingMail{begun: make(chan struct{}, 1), release: make(chan struct{})}
	d.srv.mailer = mail
	defer close(mail.release)

	req := httptest.NewRequest(http.MethodPost, "/v2/auth/forgot-password", strings.NewReader(`{"email":"`+email+`"}`))
	req.Header.Set("Content-Type", "application/json")
	req.RemoteAddr = "198.51.100.31:4321" // the forgot-password limit is per address, and shared by the package's tests
	rec := httptest.NewRecorder()
	d.srv.ServeHTTP(rec, req) // returns only once the answer is complete
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d", rec.Code)
	}
	select {
	case <-mail.begun:
	case <-time.After(5 * time.Second):
		t.Fatal("no reset mail went out after the answer")
	}
}

// A link in an email sent before the email carried only its code goes where a new code is sent.
func TestOldVerificationLinkGoesToVerifyPending(t *testing.T) {
	d := newDBTest(t)
	rec := d.do(account{}, http.MethodGet, "/verify?token=sent-before-the-deploy", nil)
	if rec.Code != http.StatusSeeOther || rec.Header().Get("Location") != "/verify-pending" {
		t.Fatalf("old link: %d to %q, want a redirect to /verify-pending", rec.Code, rec.Header().Get("Location"))
	}
}
