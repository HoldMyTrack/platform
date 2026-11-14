package httpapi

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// fakeSiteverify answers like Cloudflare's siteverify: success for the token "pass", and
// records what it was sent.
func fakeSiteverify(t *testing.T, status int) (*httptest.Server, *[]string) {
	t.Helper()
	var calls []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err != nil {
			t.Errorf("siteverify form: %v", err)
		}
		calls = append(calls, r.PostForm.Encode())
		if status != http.StatusOK {
			w.WriteHeader(status)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		if r.PostForm.Get("response") == "pass" {
			w.Write([]byte(`{"success":true}`))
		} else {
			w.Write([]byte(`{"success":false,"error-codes":["invalid-input-response"]}`))
		}
	}))
	t.Cleanup(srv.Close)
	return srv, &calls
}

func testTurnstile(url string) turnstile {
	t := newTurnstile("site-key", "secret-key")
	t.verifyURL = url
	return t
}

func TestTurnstileVerify(t *testing.T) {
	srv, calls := fakeSiteverify(t, http.StatusOK)
	ts := testTurnstile(srv.URL)
	ctx := context.Background()

	if ok, err := ts.verify(ctx, "", "203.0.113.7"); ok || err != nil {
		t.Errorf("empty token: ok=%v err=%v, want false, nil", ok, err)
	}
	if len(*calls) != 0 {
		t.Errorf("empty token sent %d requests, want none", len(*calls))
	}
	if ok, err := ts.verify(ctx, "pass", "203.0.113.7"); !ok || err != nil {
		t.Errorf("passing token: ok=%v err=%v, want true, nil", ok, err)
	}
	if got := (*calls)[0]; got != "remoteip=203.0.113.7&response=pass&secret=secret-key" {
		t.Errorf("siteverify sent %q", got)
	}
	if ok, err := ts.verify(ctx, "forged", ""); ok || err != nil {
		t.Errorf("failing token: ok=%v err=%v, want false, nil", ok, err)
	}

	down, _ := fakeSiteverify(t, http.StatusInternalServerError)
	if ok, err := testTurnstile(down.URL).verify(ctx, "pass", ""); ok || err == nil {
		t.Errorf("siteverify down: ok=%v err=%v, want false and an error", ok, err)
	}
}

func postSignup(s *Server, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, "/signup", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Origin", "https://app.example")
	rec := httptest.NewRecorder()
	s.ServeHTTP(rec, req)
	return rec
}

func TestSignupPageTurnstile(t *testing.T) {
	srv, calls := fakeSiteverify(t, http.StatusOK)
	s := newPagesTestServer(t)
	s.SetTurnstile("site-key", "secret-key")
	s.turnstile.verifyURL = srv.URL

	rec := httptest.NewRecorder()
	s.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/signup", nil))
	body := rec.Body.String()
	for _, w := range []string{`data-sitekey="site-key"`, `src="https://challenges.cloudflare.com/turnstile/v0/api.js"`} {
		if !strings.Contains(body, w) {
			t.Errorf("/signup: missing %q", w)
		}
	}
	if csp := rec.Header().Get("Content-Security-Policy"); !strings.Contains(csp, "script-src 'self' https://challenges.cloudflare.com;") {
		t.Errorf("/signup CSP %q doesn't allow the widget's script", csp)
	}
	rec = httptest.NewRecorder()
	s.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/signin", nil))
	if csp := rec.Header().Get("Content-Security-Policy"); csp != contentSecurityPolicy {
		t.Errorf("/signin CSP %q, want the default", csp)
	}

	// Without a token the form is refused before the account core looks at it, and shown
	// again with the widget.
	rec = postSignup(s, "email=someone%40example.com&password=short")
	if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "Complete the check above the button") || !strings.Contains(rec.Body.String(), `data-sitekey="site-key"`) {
		t.Errorf("no token: status %d, body without the Turnstile message or widget", rec.Code)
	}
	if rec = postSignup(s, "email=someone%40example.com&password=short&cf-turnstile-response=forged"); rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "Complete the check above the button") {
		t.Errorf("forged token: status %d, body without the Turnstile message", rec.Code)
	}
	// A passing token reaches the account core, which then rejects the short password.
	if rec = postSignup(s, "email=someone%40example.com&password=short&cf-turnstile-response=pass"); !strings.Contains(rec.Body.String(), "Password must be at least 8 characters.") {
		t.Errorf("passing token: didn't reach the password check")
	}
	if len(*calls) != 2 {
		t.Errorf("siteverify called %d times, want 2", len(*calls))
	}
}

func TestSignupPageWithoutTurnstile(t *testing.T) {
	s := newPagesTestServer(t)
	rec := httptest.NewRecorder()
	s.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/signup", nil))
	if body := rec.Body.String(); strings.Contains(body, "cf-turnstile") || strings.Contains(body, "challenges.cloudflare.com") {
		t.Errorf("/signup shows Turnstile with no site key")
	}
	if csp := rec.Header().Get("Content-Security-Policy"); csp != contentSecurityPolicy {
		t.Errorf("/signup CSP %q, want the default", csp)
	}
}