package httpapi

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/HoldMyTrack/platform/services/server/internal/i18n"
)

// Sign in with Google (docs/SPEC.md FR-1.9, docs/adr/0009-google-sign-in-server-side-code-flow.md)
// — the OAuth 2.0 authorization-code flow with PKCE, run entirely server-side: the browser
// navigates to handleGoogleStart, Google redirects back to handleGoogleCallback, and the
// callback ends in the same startSession every other sign-in path uses. No Google JS SDK on the
// client and no OAuth/JWT library here — the id_token arrives straight from Google's token
// endpoint over TLS, which OpenID Connect Core §3.1.3.7 accepts in place of verifying its
// signature, so decoding and checking its claims is all that's left to do.

const (
	googleAuthURL  = "https://accounts.google.com/o/oauth2/v2/auth"
	googleTokenURL = "https://oauth2.googleapis.com/token"

	// googleCookiePath scopes oauth.go's round-trip cookie to this flow alone.
	googleCookiePath = apiPrefix + "/auth/google"
)

// GoogleOAuthConfig is what cmd/holdmytrack hands New — config.Config's three Google* values.
// An empty ClientID means the feature is off.
type GoogleOAuthConfig struct {
	ClientID     string
	ClientSecret string
	RedirectURL  string
}

// googleOAuth is GoogleOAuthConfig plus what a test needs to swap out: the token endpoint, the
// HTTP client that reaches it, and the signing keys a native client's id_token is checked
// against (google_idtoken.go).
type googleOAuth struct {
	GoogleOAuthConfig
	tokenURL string
	client   *http.Client
	keys     *googleKeySet
}

func newGoogleOAuth(cfg GoogleOAuthConfig) googleOAuth {
	client := &http.Client{Timeout: 10 * time.Second}
	return googleOAuth{GoogleOAuthConfig: cfg, tokenURL: googleTokenURL, client: client, keys: newGoogleKeySet(client)}
}

func (g googleOAuth) enabled() bool { return g.ClientID != "" }

// handleAuthProviders serves `GET /v1/auth/providers` — which optional sign-in methods this
// deployment has configured, so a client decides whether to render the Google, Facebook and
// Apple buttons from the server's own config rather than a build-time flag that could disagree with it.
// google_client_id is the web client's ID, which the Android app passes to Credential Manager
// as its serverClientId so the id_token it gets back is one handleGoogleToken accepts. It's
// public — every Google sign-in page carries it in its URL.
func (s *Server) handleAuthProviders(w http.ResponseWriter, r *http.Request) {
	resp := struct {
		Google         bool   `json:"google"`
		Facebook       bool   `json:"facebook"`
		Apple          bool   `json:"apple"`
		GoogleClientID string `json:"google_client_id,omitempty"`
	}{Google: s.google.enabled(), Facebook: s.facebook.enabled(), Apple: s.apple.enabled()}
	if resp.Google {
		resp.GoogleClientID = s.google.ClientID
	}
	writeJSON(w, http.StatusOK, resp)
}

// handleGoogleStart serves `GET /v1/auth/google/start?tz=<IANA name>` — a full-page navigation,
// not a fetch(). tz is the browser's own timezone, carried through the round trip so a brand
// new account gets it the same way handleSignup's caller sends it; anything invalid is dropped
// here and falls back to UTC at account creation.
func (s *Server) handleGoogleStart(w http.ResponseWriter, r *http.Request) {
	if !s.google.enabled() {
		writeAPIError(w, "not found", http.StatusNotFound)
		return
	}
	state, verifier, ok := s.beginOAuth(w, r, googleCookiePath, true)
	if !ok {
		return
	}

	challenge := sha256.Sum256([]byte(verifier))
	q := url.Values{
		"client_id":             {s.google.ClientID},
		"redirect_uri":          {s.google.RedirectURL},
		"response_type":         {"code"},
		"scope":                 {"openid email profile"},
		"state":                 {state},
		"code_challenge":        {base64.RawURLEncoding.EncodeToString(challenge[:])},
		"code_challenge_method": {"S256"},
		// Always show the account chooser — someone signed into several Google accounts
		// should pick one deliberately, not be silently signed in with whichever was last used.
		"prompt": {"select_account"},
	}
	http.Redirect(w, r, googleAuthURL+"?"+q.Encode(), http.StatusFound)
}

// handleGoogleCallback serves `GET /v1/auth/google/callback` — where Google sends the browser
// back. Every failure, whatever its cause (the user cancelled, a stale or forged state, Google
// unreachable, an unusable id_token), lands on the same `/signin?error=google` redirect: the
// detail goes to the log, not the URL, for handleLogin's same "don't tell a caller more than it
// needs" reasoning.
func (s *Server) handleGoogleCallback(w http.ResponseWriter, r *http.Request) {
	if !s.google.enabled() {
		writeAPIError(w, "not found", http.StatusNotFound)
		return
	}
	rt, err := s.readOAuthCallback(w, r, googleCookiePath)
	fail := func(msg string, err error) {
		s.log.Warn("google sign-in failed: "+msg, "err", err)
		s.failOAuth(w, r, rt, "google")
	}
	if err != nil {
		fail("callback", err)
		return
	}
	ctx := r.Context()
	claims, err := s.exchangeGoogleCode(ctx, rt.code, rt.verifier)
	if err != nil {
		fail("code exchange", err)
		return
	}
	userID, err := s.resolveVerifiedUser(ctx, "google", claims.Sub, claims.Email, claims.Name, rt.tz)
	if err != nil {
		fail("account resolution", err)
		return
	}
	if err := s.finishOAuth(w, r, rt, userID); err != nil {
		fail("session start", err)
	}
}

// handleGoogleToken serves `POST /v1/auth/google/token` `{id_token, tz}` — Sign in with Google
// for a native client (docs/IMPLEMENTATION.md §4.9). The Android app gets the id_token from
// Credential Manager's account picker and posts it here; its signature is verified
// (verifyGoogleIDToken), the account resolved exactly as the web callback does, and the answer
// is the same session JSON as a password sign-in. Every failure is a 401 with the web's own
// "Couldn't sign in with Google" wording; the detail goes to the log.
func (s *Server) handleGoogleToken(w http.ResponseWriter, r *http.Request) {
	if !s.google.enabled() {
		writeAPIError(w, "not found", http.StatusNotFound)
		return
	}
	var req struct {
		IDToken string `json:"id_token"`
		TZ      string `json:"tz"`
	}
	if err := decodeJSON(r.Body, &req); err != nil {
		writeAPIError(w, bodyError(err, "invalid JSON body"), http.StatusBadRequest)
		return
	}
	fail := func(msg string, err error) {
		s.log.Warn("google sign-in failed: "+msg, "err", err)
		writeError(w, http.StatusUnauthorized, "google_failed", i18n.Get(requestLang(r)).T("signin.google_failed"))
	}
	ctx := r.Context()
	claims, err := s.verifyGoogleIDToken(ctx, req.IDToken, time.Now())
	if err != nil {
		fail("id_token", err)
		return
	}
	tz, _ := normalizeTimezone(req.TZ)
	userID, err := s.resolveVerifiedUser(ctx, "google", claims.Sub, claims.Email, claims.Name, tz)
	if err != nil {
		fail("account resolution", err)
		return
	}
	s.writeSession(w, r, userID, sessionTTL, http.StatusOK)
}

// googleClaims is the subset of Google's id_token payload this flow reads.
type googleClaims struct {
	Iss   string `json:"iss"`
	Aud   string `json:"aud"`
	Exp   int64  `json:"exp"`
	Sub   string `json:"sub"`
	Email string `json:"email"`
	// Google sends a JSON boolean; some older Google endpoints sent the string "true", so
	// accept either rather than failing on a representation change.
	EmailVerified any    `json:"email_verified"`
	Name          string `json:"name"`
}

// exchangeGoogleCode trades the authorization code for tokens at Google's token endpoint and
// returns the id_token's validated claims. The access token is discarded — this flow only
// needs to know who the user is, never to call a Google API on their behalf.
func (s *Server) exchangeGoogleCode(ctx context.Context, code, verifier string) (googleClaims, error) {
	if code == "" {
		return googleClaims{}, errors.New("no code in callback")
	}
	form := url.Values{
		"code":          {code},
		"client_id":     {s.google.ClientID},
		"client_secret": {s.google.ClientSecret},
		"redirect_uri":  {s.google.RedirectURL},
		"grant_type":    {"authorization_code"},
		"code_verifier": {verifier},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.google.tokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return googleClaims{}, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := s.google.client.Do(req)
	if err != nil {
		return googleClaims{}, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return googleClaims{}, err
	}
	if resp.StatusCode != http.StatusOK {
		return googleClaims{}, fmt.Errorf("token endpoint returned %d: %s", resp.StatusCode, body)
	}
	var tok struct {
		IDToken string `json:"id_token"`
	}
	if err := json.Unmarshal(body, &tok); err != nil {
		return googleClaims{}, fmt.Errorf("token response: %w", err)
	}
	return parseGoogleIDToken(tok.IDToken, s.google.ClientID, time.Now())
}

// parseGoogleIDToken decodes an id_token's payload and applies the checks of
// OpenID Connect Core §3.1.3.7 that still apply when the token came straight from the token
// endpoint over TLS: issuer, audience, expiry — plus email_verified, since the email is what an existing
// account gets linked by (resolveVerifiedUser) and an unverified one proves nothing.
func parseGoogleIDToken(idToken, clientID string, now time.Time) (googleClaims, error) {
	segs := strings.Split(idToken, ".")
	if len(segs) != 3 {
		return googleClaims{}, errors.New("id_token is not a JWT")
	}
	payload, err := base64.RawURLEncoding.DecodeString(segs[1])
	if err != nil {
		return googleClaims{}, fmt.Errorf("id_token payload: %w", err)
	}
	var c googleClaims
	if err := json.Unmarshal(payload, &c); err != nil {
		return googleClaims{}, fmt.Errorf("id_token payload: %w", err)
	}
	switch {
	case c.Iss != "accounts.google.com" && c.Iss != "https://accounts.google.com":
		return googleClaims{}, fmt.Errorf("unexpected issuer %q", c.Iss)
	case c.Aud != clientID:
		return googleClaims{}, fmt.Errorf("unexpected audience %q", c.Aud)
	case now.Unix() >= c.Exp:
		return googleClaims{}, errors.New("id_token expired")
	case c.Sub == "":
		return googleClaims{}, errors.New("id_token has no subject")
	case c.EmailVerified != true && c.EmailVerified != "true":
		return googleClaims{}, errors.New("google account email is not verified")
	}
	email, err := normalizeEmail(c.Email)
	if err != nil {
		return googleClaims{}, err
	}
	c.Email = email
	return c, nil
}
