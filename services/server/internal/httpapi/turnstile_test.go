package httpapi

import (
	"context"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"
)

// fakeSiteverify answers like Cloudflare's siteverify: success for the token "pass", a refused
// secret for "secret-key" sent as anything but the secret, and records what it was sent.
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
		switch {
		case r.PostForm.Get("secret") != "secret-key":
			w.Write([]byte(`{"success":false,"error-codes":["invalid-input-secret"]}`))
		case r.PostForm.Get("response") == "pass":
			w.Write([]byte(`{"success":true}`))
		default:
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

	if v, err := ts.verify(ctx, "", "203.0.113.7"); v.Success || err != nil {
		t.Errorf("empty token: %+v, %v, want a failure and no error", v, err)
	}
	if len(*calls) != 0 {
		t.Errorf("empty token sent %d requests, want none", len(*calls))
	}
	if v, err := ts.verify(ctx, "pass", "203.0.113.7"); !v.Success || err != nil {
		t.Errorf("passing token: %+v, %v, want success", v, err)
	}
	if got := (*calls)[0]; got != "remoteip=203.0.113.7&response=pass&secret=secret-key" {
		t.Errorf("siteverify sent %q", got)
	}
	if v, err := ts.verify(ctx, "forged", ""); v.Success || err != nil || !slices.Equal(v.ErrorCodes, []string{"invalid-input-response"}) {
		t.Errorf("failing token: %+v, %v, want a failure with its code and no error", v, err)
	}

	wrong := newTurnstile("site-key", "wrong-secret")
	wrong.verifyURL = srv.URL
	if _, err := wrong.verify(ctx, "pass", ""); err == nil {
		t.Error("refused secret: no error, want one, since no visitor could pass")
	}

	down, _ := fakeSiteverify(t, http.StatusInternalServerError)
	if v, err := testTurnstile(down.URL).verify(ctx, "pass", ""); v.Success || err == nil {
		t.Errorf("siteverify down: %+v, %v, want a failure and an error", v, err)
	}

	huge := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"success":true,"hostname":"` + strings.Repeat("a", maxSiteverifyBytes) + `"}`))
	}))
	t.Cleanup(huge.Close)
	if v, err := testTurnstile(huge.URL).verify(ctx, "pass", ""); v.Success || err == nil {
		t.Errorf("answer past %d bytes: %+v, %v, want an error", maxSiteverifyBytes, v, err)
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

	// Input the account core refuses costs no call to Cloudflare.
	if rec = postSignup(s, "email=someone%40example.com&password=short&cf-turnstile-response=pass"); !strings.Contains(rec.Body.String(), "Password must be at least 8 characters.") {
		t.Errorf("short password: status %d, body without the password message", rec.Code)
	}
	// Without a token, or with a forged one, the form is refused and shown again with the widget.
	rec = postSignup(s, "email=someone%40example.com&password=long+enough")
	if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "Complete the check above the button") || !strings.Contains(rec.Body.String(), `data-sitekey="site-key"`) {
		t.Errorf("no token: status %d, body without the Turnstile message or widget", rec.Code)
	}
	if csp := rec.Header().Get("Content-Security-Policy"); !strings.Contains(csp, turnstileScriptOrigin) {
		t.Errorf("refused /signup CSP %q doesn't allow the widget's script", csp)
	}
	if rec = postSignup(s, "email=someone%40example.com&password=long+enough&cf-turnstile-response=forged"); rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "Complete the check above the button") {
		t.Errorf("forged token: status %d, body without the Turnstile message", rec.Code)
	}
	if len(*calls) != 1 {
		t.Errorf("siteverify called %d times, want 1", len(*calls))
	}
	// A failed check gives its slot back.
	if n := s.signupLimiter.current("192.0.2.1").count; n != 0 {
		t.Errorf("signup slots taken after refused checks: %d, want 0", n)
	}
}

func TestSignupPageTurnstileUnavailable(t *testing.T) {
	down, _ := fakeSiteverify(t, http.StatusBadGateway)
	s := newPagesTestServer(t)
	s.SetTurnstile("site-key", "secret-key")
	s.turnstile.verifyURL = down.URL
	if rec := postSignup(s, "email=someone%40example.com&password=long+enough&cf-turnstile-response=pass"); rec.Code != http.StatusServiceUnavailable || !strings.Contains(rec.Body.String(), "The bot check is unavailable; try again later.") {
		t.Errorf("siteverify down: status %d, body without the try-later message", rec.Code)
	}
}

func TestSignupPageRateLimitBeforeTurnstile(t *testing.T) {
	srv, calls := fakeSiteverify(t, http.StatusOK)
	s := newPagesTestServer(t)
	s.SetTurnstile("site-key", "secret-key")
	s.turnstile.verifyURL = srv.URL
	s.SetSignupsPerHour(0)
	if rec := postSignup(s, "email=someone%40example.com&password=long+enough&cf-turnstile-response=pass"); rec.Code != http.StatusTooManyRequests {
		t.Errorf("past the limit: status %d, want 429", rec.Code)
	}
	if len(*calls) != 0 {
		t.Errorf("past the limit: siteverify called %d times, want none", len(*calls))
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
