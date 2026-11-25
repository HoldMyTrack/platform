package httpapi

// Covers docs/SPEC.md FR-1.5, FR-1.8 and FR-1.10: an account Facebook made under someone else's
// address can't keep its Facebook link once the address's owner takes the account over.

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// facebookRecovery is a database test with Facebook configured against a fake Graph API whose
// /me answers as the Facebook account subject with email.
type facebookRecovery struct {
	*dbTest
	graph *fakeGraph
}

func newFacebookRecovery(t *testing.T) facebookRecovery {
	d := newDBTest(t)
	d.srv.mailer = &sentMail{}
	graph := &fakeGraph{}
	f := newFacebookOAuth(FacebookOAuthConfig{
		AppID: testAppID, AppSecret: "secret", RedirectURL: "https://app.example/v2/auth/facebook/callback",
	})
	f.graphURL = graph.serve(t).URL
	d.srv.facebook = f
	return facebookRecovery{d, graph}
}

// facebookAccount makes the account a Facebook sign-in creates for an address not yet in use
// (resolveFacebookUser): no password, the address unverified, a verification code mailed.
func (f facebookRecovery) facebookAccount(verified bool) (a account, email, subject string) {
	f.t.Helper()
	ctx := context.Background()
	stamp := time.Now().UnixNano()
	email = fmt.Sprintf("victim-%d@holdmytrack.invalid", stamp)
	subject = fmt.Sprintf("fb-%d", stamp)
	if err := f.pool.QueryRow(ctx, `INSERT INTO users (email, email_verified) VALUES ($1, $2) RETURNING id`, email, verified).Scan(&a.id); err != nil {
		f.t.Fatal(err)
	}
	f.t.Cleanup(func() {
		if _, err := f.pool.Exec(context.Background(), `DELETE FROM users WHERE id = $1`, a.id); err != nil {
			f.t.Errorf("delete account: %v", err)
		}
	})
	if _, err := f.pool.Exec(ctx, `INSERT INTO user_identities (user_id, provider, subject) VALUES ($1, 'facebook', $2)`, a.id, subject); err != nil {
		f.t.Fatal(err)
	}
	if !verified {
		if err := f.srv.sendVerificationEmail(ctx, a.id, email, "en"); err != nil {
			f.t.Fatal(err)
		}
	}
	return a, email, subject
}

// facebookCallback finishes a Facebook round trip as subject with the callback query given
// (Facebook's answer). It returns the redirect's target and the session it started.
func (f facebookRecovery) facebookCallback(query, subject, email string) (location string, as account) {
	f.t.Helper()
	f.graph.me = map[string]string{"id": subject, "email": email, "name": "Some One"}
	req := httptest.NewRequest(http.MethodGet, "/v2/auth/facebook/callback?"+query, nil)
	req.AddCookie(&http.Cookie{Name: oauthCookieName, Value: "s..UTC."})
	rec := serveChecked(f.t, f.srv.ServeHTTP, req)
	if rec.Code != http.StatusFound {
		f.t.Fatalf("callback: %d, want a redirect", rec.Code)
	}
	for _, c := range rec.Result().Cookies() {
		if c.Name == sessionCookieName && c.Value != "" {
			as.session = c.Value
		}
	}
	return rec.Header().Get("Location"), as
}

func (f facebookRecovery) facebookLinks(a account) int {
	f.t.Helper()
	var n int
	if err := f.pool.QueryRow(context.Background(), `SELECT count(*) FROM user_identities WHERE user_id = $1 AND provider = 'facebook'`, a.id).Scan(&n); err != nil {
		f.t.Fatal(err)
	}
	return n
}

// A Facebook-made account is verified only by the code typed in a session signed in to it, which
// whoever holds the Facebook account starts; the address's owner who isn't them resets the
// password instead. The first verification keeps the Facebook link and ends unredeemed app
// sign-ins.
func TestFacebookMadeAccountVerifiesInItsOwnSession(t *testing.T) {
	f := newFacebookRecovery(t)
	a, email, subject := f.facebookAccount(false)
	code := f.mailedCode(email)
	if rec := f.do(account{}, http.MethodPost, "/v2/auth/verify-code", map[string]string{"code": code}); rec.Code != http.StatusUnauthorized {
		t.Fatalf("code typed signed out: %d, want 401", rec.Code)
	}

	_, session := f.facebookCallback("state=s&code=x", subject, email)
	if session.session == "" {
		t.Fatal("the Facebook sign-in started no session")
	}
	session.id = a.id
	if _, err := f.srv.createHandoff(context.Background(), a.id, testChallenge("another-app")); err != nil {
		t.Fatal(err)
	}
	if status, errCode := f.typeCode(session, code); status != http.StatusOK {
		t.Fatalf("code typed in the Facebook session: %d %q, want 200", status, errCode)
	}
	if _, verified := f.email(a); !verified {
		t.Fatal("not verified by the session signed in with Facebook")
	}
	if f.facebookLinks(a) != 1 {
		t.Error("verifying dropped the account's own Facebook link")
	}
	var codes int
	if err := f.pool.QueryRow(context.Background(), `SELECT count(*) FROM auth_handoffs WHERE user_id = $1`, a.id).Scan(&codes); err != nil || codes != 0 {
		t.Errorf("%d app sign-in codes left after the first verification (%v), want none", codes, err)
	}
}

// The address's owner resets the password of an account Facebook made under their address and
// verifies it: the Facebook link is gone, and that Facebook account is refused from then on.
func TestResetDropsAnUnverifiedAccountsFacebookLink(t *testing.T) {
	f := newFacebookRecovery(t)
	a, email, subject := f.facebookAccount(false)

	if rec := f.do(account{}, http.MethodPost, "/v2/auth/forgot-password", map[string]any{"email": email}); rec.Code != http.StatusOK {
		t.Fatalf("forgot-password: %d", rec.Code)
	}
	var owner account
	f.decode(f.do(account{}, http.MethodPost, "/v2/auth/reset-password", map[string]any{
		"token": f.mailedToken(email, "/reset"), "password": "the-owners-password",
	}), http.StatusOK, &struct {
		SessionToken *string `json:"session_token"`
	}{&owner.session})
	if f.facebookLinks(a) != 0 {
		t.Fatal("the reset kept the Facebook link")
	}
	owner.id = a.id
	if status, errCode := f.typeCode(owner, f.mailedCode(email)); status != http.StatusOK {
		t.Fatalf("the owner's code: %d %q, want 200", status, errCode)
	}

	if location, _ := f.facebookCallback("state=s&code=x", subject, email); !strings.HasSuffix(location, "/signin?error=facebook_email_in_use") {
		t.Errorf("the Facebook account after the reset: sent to %q, want refused with facebook_email_in_use", location)
	}
}

// A verified account's Facebook link was made by whoever verified the address, so a reset keeps it.
func TestResetKeepsAVerifiedAccountsFacebookLink(t *testing.T) {
	f := newFacebookRecovery(t)
	a, email, _ := f.facebookAccount(true)
	if rec := f.do(account{}, http.MethodPost, "/v2/auth/forgot-password", map[string]any{"email": email}); rec.Code != http.StatusOK {
		t.Fatalf("forgot-password: %d", rec.Code)
	}
	if rec := f.do(account{}, http.MethodPost, "/v2/auth/reset-password", map[string]any{
		"token": f.mailedToken(email, "/reset"), "password": "the-owners-password",
	}); rec.Code != http.StatusOK {
		t.Fatalf("reset-password: %d", rec.Code)
	}
	if f.facebookLinks(a) != 1 {
		t.Error("the reset dropped a verified account's Facebook link")
	}
}

// A reset ends an app sign-in code whoever linked Facebook hadn't redeemed yet.
func TestResetEndsUnredeemedAppSignIns(t *testing.T) {
	f := newFacebookRecovery(t)
	a, email, _ := f.facebookAccount(false)
	if _, err := f.srv.createHandoff(context.Background(), a.id, testChallenge("the-verifier")); err != nil {
		t.Fatal(err)
	}
	if rec := f.do(account{}, http.MethodPost, "/v2/auth/forgot-password", map[string]any{"email": email}); rec.Code != http.StatusOK {
		t.Fatalf("forgot-password: %d", rec.Code)
	}
	if rec := f.do(account{}, http.MethodPost, "/v2/auth/reset-password", map[string]any{
		"token": f.mailedToken(email, "/reset"), "password": "the-owners-password",
	}); rec.Code != http.StatusOK {
		t.Fatalf("reset-password: %d", rec.Code)
	}
	var left int
	if err := f.pool.QueryRow(context.Background(), `SELECT count(*) FROM auth_handoffs WHERE user_id = $1`, a.id).Scan(&left); err != nil || left != 0 {
		t.Errorf("%d app sign-in codes left after the reset (%v), want none", left, err)
	}
}
