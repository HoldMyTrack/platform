package httpapi

// Covers docs/SPEC.md FR-1.8 (email verification).

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
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

// verificationToken is the token in the newest verification link a's pending address was sent.
func (d *dbTest) verificationToken(a account) string {
	d.t.Helper()
	var to string
	if err := d.pool.QueryRow(context.Background(),
		`SELECT email FROM email_verifications WHERE user_id = $1 ORDER BY created_at DESC LIMIT 1`, a.id).Scan(&to); err != nil {
		d.t.Fatalf("read verification address: %v", err)
	}
	return d.mailedToken(to, "/verify")
}

// confirmLink presses the Confirm button the verification link's page shows, as as (the zero
// account is signed out).
func (d *dbTest) confirmLink(as account, token string) *httptest.ResponseRecorder {
	d.t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/verify", strings.NewReader(url.Values{"token": {token}}.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Origin", "https://app.example")
	if as.session != "" {
		req.Header.Set("Authorization", bearerPrefix+as.session)
	}
	rec := httptest.NewRecorder()
	d.srv.ServeHTTP(rec, req)
	return rec
}

// Opening the link, as a mail scanner does, confirms nothing: the page only offers the button,
// and the link still works when it's pressed. A dead link says so at once, and the browser
// signed in to the link's account confirms on opening.
func TestOpeningTheVerificationLinkConfirmsOnlyInItsOwnBrowser(t *testing.T) {
	d := newDBTest(t)
	d.srv.mailer = &sentMail{}
	unverified := func() account {
		a := d.newAccount(false)
		if _, err := d.pool.Exec(context.Background(), `UPDATE users SET email_verified = false WHERE id = $1`, a.id); err != nil {
			t.Fatal(err)
		}
		email, _ := d.email(a)
		if err := d.srv.sendVerificationEmail(context.Background(), a.id, email, "en"); err != nil {
			t.Fatal(err)
		}
		return a
	}

	a := unverified()
	token := d.verificationToken(a)
	rec := d.do(account{}, http.MethodGet, "/verify?token="+token, nil)
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `action="/verify"`) || !strings.Contains(rec.Body.String(), `name="token" value="`+token+`"`) {
		t.Fatalf("opening the link signed out: %d, want the page with its Confirm button:\n%s", rec.Code, rec.Body)
	}
	if _, verified := d.email(a); verified {
		t.Fatal("opening the link signed out verified the address")
	}
	if rec := d.confirmLink(account{}, token); rec.Code != http.StatusSeeOther {
		t.Fatalf("pressing Confirm after the link was opened: %d, want a redirect", rec.Code)
	}
	if _, verified := d.email(a); !verified {
		t.Fatal("pressing Confirm didn't verify the address")
	}

	rec = d.do(account{}, http.MethodGet, "/verify?token="+token, nil)
	if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), `role="alert"`) || strings.Contains(rec.Body.String(), `action="/verify"`) {
		t.Fatalf("opening a used link: %d, want the invalid-link message without a button:\n%s", rec.Code, rec.Body)
	}

	own := unverified()
	rec = d.do(own, http.MethodGet, "/verify?token="+d.verificationToken(own), nil)
	if rec.Code != http.StatusSeeOther || rec.Header().Get("Location") != "/" {
		t.Fatalf("opening the link in the account's own browser: %d to %q, want a redirect to /", rec.Code, rec.Header().Get("Location"))
	}
	if _, verified := d.email(own); !verified {
		t.Fatal("opening the link in the account's own browser didn't verify the address")
	}
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

	token := d.verificationToken(a)
	if rec := d.do(account{}, http.MethodPost, "/v2/auth/verify-email", map[string]string{"token": token}); rec.Code != http.StatusNoContent {
		t.Fatalf("confirming from elsewhere: %d, want 204 and no session", rec.Code)
	}
	if email, verified := d.email(a); email != target || !verified {
		t.Fatalf("after confirming: email %q verified %v, want %q verified", email, verified, target)
	}
}

// A changed address's link signs in only the account's own browser, not a signed-out reader or
// one signed in to another account (IMPLEMENTATION.md §4.9).
func TestChangedAddressLinkSignsInOnlyTheAccountsOwnBrowser(t *testing.T) {
	d := newDBTest(t)
	d.srv.mailer = &sentMail{}
	sender := d.newAccount(false)
	before, _ := d.email(sender)
	d.decode(d.do(sender, http.MethodPatch, "/v2/auth/email", map[string]string{"email": "second-" + before}), http.StatusOK, nil)

	rec := d.confirmLink(account{}, d.verificationToken(sender))
	if rec.Code != http.StatusSeeOther || rec.Header().Get("Location") != "/signin?verified" {
		t.Fatalf("link opened signed out: %d to %q, want a redirect to /signin?verified", rec.Code, rec.Header().Get("Location"))
	}
	for _, c := range rec.Result().Cookies() {
		if c.Name == sessionCookieName && c.Value != "" {
			t.Fatalf("signed the reader in to the sender's account: %v", c)
		}
	}
	if email, _ := d.email(sender); email != "second-"+before {
		t.Fatalf("address %q, want the confirmed one", email)
	}

	// Opened in a browser signed in to another account: verified, and that browser stays its own.
	reader := d.newAccount(false)
	d.decode(d.do(sender, http.MethodPatch, "/v2/auth/email", map[string]string{"email": "third-" + before}), http.StatusOK, nil)
	rec = d.confirmLink(reader, d.verificationToken(sender))
	if rec.Code != http.StatusSeeOther || rec.Header().Get("Location") != "/signin?verified" {
		t.Fatalf("link opened in another account's browser: %d to %q, want a redirect to /signin?verified", rec.Code, rec.Header().Get("Location"))
	}
	for _, c := range rec.Result().Cookies() {
		if c.Name == sessionCookieName {
			t.Fatalf("replaced the reader's session: %v", c)
		}
	}
	var me struct{ Email string }
	d.decode(d.do(reader, http.MethodGet, "/v2/auth/me", nil), http.StatusOK, &me)
	if readerEmail, _ := d.email(reader); me.Email != readerEmail {
		t.Fatalf("the reader's browser is signed in as %q, want its own account %q", me.Email, readerEmail)
	}

	// Opened in the account's own browser: it carries on with the session it has.
	d.decode(d.do(sender, http.MethodPatch, "/v2/auth/email", map[string]string{"email": "fourth-" + before}), http.StatusOK, nil)
	rec = d.confirmLink(sender, d.verificationToken(sender))
	if rec.Code != http.StatusSeeOther || rec.Header().Get("Location") != "/" {
		t.Fatalf("link opened in the account's own browser: %d to %q, want a redirect to /", rec.Code, rec.Header().Get("Location"))
	}
	for _, c := range rec.Result().Cookies() {
		if c.Name == sessionCookieName {
			t.Errorf("started a second session for a browser already signed in: %v", c)
		}
	}
	if rec := d.do(sender, http.MethodGet, "/v2/auth/me", nil); rec.Code != http.StatusOK {
		t.Errorf("the account's own browser after confirming: %d, want still signed in", rec.Code)
	}
}

// A link sent to the account's address before a change confirms nothing after it: it can't
// mark the new, unproven address verified.
func TestVerificationLinkConfirmsOnlyItsOwnAddress(t *testing.T) {
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
	oldToken := d.verificationToken(a)

	d.decode(d.do(a, http.MethodPatch, "/v2/auth/email", map[string]string{"email": "other-" + before}), http.StatusOK, nil)
	rec := d.do(account{}, http.MethodPost, "/v2/auth/verify-email", map[string]string{"token": oldToken})
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("old link: status %d, want 400", rec.Code)
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

// The emailed /verify link verifies whoever's link it is, but doesn't switch a browser signed
// in to a different account over to that one — a link someone sent from their own inbox would
// otherwise move the reader into the sender's account.
func TestVerifyLinkKeepsAnotherAccountsSession(t *testing.T) {
	d := newDBTest(t)
	d.srv.mailer = &sentMail{}
	reader, sender := d.newAccount(false), d.newAccount(false)
	if _, err := d.pool.Exec(context.Background(), `UPDATE users SET email_verified = false WHERE id = $1`, sender.id); err != nil {
		t.Fatal(err)
	}
	email, _ := d.email(sender)
	if err := d.srv.sendVerificationEmail(context.Background(), sender.id, email, "en"); err != nil {
		t.Fatal(err)
	}

	rec := d.confirmLink(reader, d.verificationToken(sender))
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("status %d, want a redirect", rec.Code)
	}
	for _, c := range rec.Result().Cookies() {
		if c.Name == sessionCookieName {
			t.Fatalf("set a session cookie for the sender's account: %v", c)
		}
	}
	if _, verified := d.email(sender); !verified {
		t.Fatal("the sender's address wasn't verified")
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

// An account's first verification proves who owns the address, not who chose its password
// (SPEC FR-1.8): a link opened anywhere else verifies without signing in and ends the sessions
// whoever signed up holds, while the signing-up browser stays signed in.
func TestFirstVerificationSignsInOnlyTheAccountsOwnBrowser(t *testing.T) {
	d := newDBTest(t)
	d.srv.mailer = &sentMail{}
	unverified := func() account {
		a := d.newAccount(false)
		if _, err := d.pool.Exec(context.Background(), `UPDATE users SET email_verified = false WHERE id = $1`, a.id); err != nil {
			t.Fatal(err)
		}
		email, _ := d.email(a)
		if err := d.srv.sendVerificationEmail(context.Background(), a.id, email, "en"); err != nil {
			t.Fatal(err)
		}
		return a
	}

	// Someone signed up with another person's address; its owner opens the link.
	squatter := unverified()
	rec := d.confirmLink(account{}, d.verificationToken(squatter))
	if rec.Code != http.StatusSeeOther || rec.Header().Get("Location") != "/signin?verified" {
		t.Fatalf("link opened elsewhere: %d to %q, want a redirect to /signin?verified", rec.Code, rec.Header().Get("Location"))
	}
	for _, c := range rec.Result().Cookies() {
		if c.Name == sessionCookieName && c.Value != "" {
			t.Fatalf("signed the opener in: %v", c)
		}
	}
	if _, verified := d.email(squatter); !verified {
		t.Fatal("the address wasn't verified")
	}
	if rec := d.do(squatter, http.MethodGet, "/v2/auth/me", nil); rec.Code != http.StatusUnauthorized {
		t.Errorf("the sign-up's own session after verification elsewhere: %d, want 401", rec.Code)
	}

	// The JSON endpoint likewise: 204, no session.
	other := unverified()
	if rec := d.do(account{}, http.MethodPost, "/v2/auth/verify-email", map[string]any{"token": d.verificationToken(other)}); rec.Code != http.StatusNoContent {
		t.Errorf("verify-email from elsewhere: %d, want 204", rec.Code)
	}

	// The signing-up browser opens its own link: signed in, and its session kept.
	owner := unverified()
	d.decode(d.do(owner, http.MethodPost, "/v2/auth/verify-email", map[string]any{"token": d.verificationToken(owner)}), http.StatusOK, nil)
	if rec := d.do(owner, http.MethodGet, "/v2/auth/me", nil); rec.Code != http.StatusOK {
		t.Errorf("the verifying browser's own session: %d, want 200", rec.Code)
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
