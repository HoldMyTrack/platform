package httpapi

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"reflect"
	"strings"
	"testing"
	"time"
)

// appChallengeVerifier is a PKCE verifier (32 bytes, base64url: 43 characters) an app keeps.
const appChallengeVerifier = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"

func TestSignupPageAction(t *testing.T) {
	good := testChallenge(appChallengeVerifier)
	for name, tc := range map[string]struct {
		challenge    string
		signedInReal bool
		want         signupAction
	}{
		"browser":                      {"", false, signupShow},
		"browser signed in":            {"", true, signupHome},
		"app":                          {good, false, signupShow},
		"app, tab signed in elsewhere": {good, true, signupShow},
		"app, bad challenge":           {"short", false, signupBadChallenge},
	} {
		if got := signupPageAction(tc.challenge, tc.signedInReal); got != tc.want {
			t.Errorf("%s: %v, want %v", name, got, tc.want)
		}
	}
}

func TestSignupForm(t *testing.T) {
	all := signupProviders{google: true, facebook: true, apple: true}
	if got, want := signupForm("", true, all, "k"), (authForm{Google: true, Facebook: true, Apple: true, Upgrading: true, TurnstileSiteKey: "k"}); !reflect.DeepEqual(got, want) {
		t.Errorf("browser: %+v, want %+v", got, want)
	}
	// An app's page offers no provider and no upgrade: either would finish in the tab.
	if got, want := signupForm("c", true, all, "k"), (authForm{AppChallenge: "c", InApp: true, TurnstileSiteKey: "k"}); !reflect.DeepEqual(got, want) {
		t.Errorf("app: %+v, want %+v", got, want)
	}
}

// The app's sign-up page carries the challenge through the form and leaves out every link that
// would lead away in the tab: the site's header and footer, and Sign in.
func TestSignupPageForApp(t *testing.T) {
	s := newPagesTestServer(t)
	challenge := testChallenge(appChallengeVerifier)
	rec := httptest.NewRecorder()
	s.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/signup?app_challenge="+challenge, nil))
	body := rec.Body.String()
	if rec.Code != http.StatusOK || !strings.Contains(body, `name="app_challenge" value="`+challenge+`"`) {
		t.Fatalf("status %d, the form without the challenge:\n%s", rec.Code, body)
	}
	for _, n := range []string{`href="/signin"`, `class="page-header`, `class="page-footer"`} {
		if strings.Contains(body, n) {
			t.Errorf("the app's page has %q", n)
		}
	}

	rec = httptest.NewRecorder()
	s.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/signup?app_challenge=short", nil))
	if rec.Code != http.StatusBadRequest {
		t.Errorf("bad challenge: status %d, want 400", rec.Code)
	}
	if rec := postSignup(s, "email=someone%40example.com&password=long+enough&app_challenge=short"); rec.Code != http.StatusBadRequest {
		t.Errorf("bad challenge posted: status %d, want 400", rec.Code)
	}
	// A refused form is shown again for the app, the challenge kept.
	rec = postSignup(s, "email=someone%40example.com&password=short&app_challenge="+challenge)
	if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), `name="app_challenge" value="`+challenge+`"`) || strings.Contains(rec.Body.String(), `href="/signin"`) {
		t.Errorf("refused: status %d, not the app's page again with its challenge", rec.Code)
	}
}

// A sign-up from the app's tab sets no cookie there and hands the app a code its verifier
// redeems for a session on the new, unverified account.
func TestAppSignupHandsOffToTheApp(t *testing.T) {
	d := newDBTest(t)
	d.srv.mailer = &sentMail{}
	email := fmt.Sprintf("app-signup-%d@holdmytrack.invalid", time.Now().UnixNano())
	t.Cleanup(func() {
		if _, err := d.pool.Exec(context.Background(), `DELETE FROM users WHERE email = $1`, email); err != nil {
			t.Errorf("clean up: %v", err)
		}
	})
	form := url.Values{"email": {email}, "password": {"long enough"}, "app_challenge": {testChallenge(appChallengeVerifier)}}
	rec := postSignup(d.srv, form.Encode())
	location, err := url.Parse(rec.Header().Get("Location"))
	if rec.Code != http.StatusSeeOther || err != nil || location.Scheme+"://"+location.Host != appRedirectURI || location.Query().Get("code") == "" {
		t.Fatalf("status %d to %q, want a redirect to %s with a code", rec.Code, rec.Header().Get("Location"), appRedirectURI)
	}
	for _, c := range rec.Result().Cookies() {
		if c.Name == sessionCookieName {
			t.Fatalf("signed the tab in: %v", c)
		}
	}
	var got struct {
		Token string `json:"session_token"`
	}
	d.decode(d.do(account{}, http.MethodPost, "/v2/auth/handoff", map[string]string{"code": location.Query().Get("code"), "verifier": appChallengeVerifier}), http.StatusOK, &got)
	var me struct {
		Email         string `json:"email"`
		EmailVerified bool   `json:"email_verified"`
	}
	d.decode(d.do(account{session: got.Token}, http.MethodGet, "/v2/auth/me", nil), http.StatusOK, &me)
	if me.Email != email || me.EmailVerified {
		t.Errorf("the app's session is on %q verified %v, want the new unverified %q", me.Email, me.EmailVerified, email)
	}
	var rows int
	if err := d.pool.QueryRow(context.Background(), `SELECT count(*) FROM email_verifications WHERE email = $1`, email).Scan(&rows); err != nil || rows != 1 {
		t.Errorf("verification emails for the new account: %d (%v), want 1", rows, err)
	}
}

// An app's account that couldn't be handed over says to sign in with it in the app, with no form
// to make it again and no link away.
func TestSignupCreatedPage(t *testing.T) {
	s := newPagesTestServer(t)
	rec := httptest.NewRecorder()
	s.renderAuth(rec, httptest.NewRequest(http.MethodPost, "/signup", nil), nil, http.StatusInternalServerError, "signup", "signup.title", true, authForm{InApp: true, Created: true, ErrorKey: "error.signup_created_sign_in"})
	body := rec.Body.String()
	if rec.Code != http.StatusInternalServerError || !strings.Contains(body, "Your account was created.") {
		t.Fatalf("status %d, without the message:\n%s", rec.Code, body)
	}
	for _, n := range []string{`action="/signup"`, `href="/signin"`, `class="page-header`, `class="page-footer"`} {
		if strings.Contains(body, n) {
			t.Errorf("the page has %q", n)
		}
	}
}

func TestFromApp(t *testing.T) {
	webView := httptest.NewRequest(http.MethodGet, "/help", nil)
	webView.AddCookie(&http.Cookie{Name: appCookieName, Value: "android"})
	for name, tc := range map[string]struct {
		r    *http.Request
		want bool
	}{
		"browser":         {httptest.NewRequest(http.MethodGet, "/signup", nil), false},
		"app's WebView":   {webView, true},
		"app sign-up tab": {httptest.NewRequest(http.MethodGet, "/signup?app_challenge=c", nil), true},
	} {
		if got := fromApp(tc.r); got != tc.want {
			t.Errorf("%s: %v, want %v", name, got, tc.want)
		}
	}
}
