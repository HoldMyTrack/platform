package httpapi

import (
	"context"
	"crypto/ecdsa"
	"crypto/rand"
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

// Sign in with Apple (docs/SPEC.md FR-1.14) — Apple's authorization-code flow, run server-side
// like Google's (google_auth.go): handleAppleStart redirects to Apple, Apple posts the browser
// back to handleAppleCallback, which trades the code for tokens and ends in the same session
// every other sign-in path starts. Apple vouches for the email it sends, so an account is
// matched the way Google's is (resolveVerifiedUser). No Apple JS SDK on the client and no JWT
// library here.
//
// Three things differ from Google:
//   - The client secret is a short-lived ES256 JWT this server signs with the Sign in with
//     Apple key (appleClientSecret), not a fixed string.
//   - Asking for the name and email makes Apple answer with a cross-site form POST
//     (response_mode=form_post), so the round-trip cookie is SameSite=None (oauthCookieSameSite)
//     and the callback is let through ServeHTTP's cross-site check (crossSiteAPIWrite).
//   - The refresh token is kept, with the client it was issued to, since Apple requires it
//     revoked when the account is deleted (apple_revoke.go). Apple also tells this server when
//     someone stops using Sign in with Apple here (apple_notifications.go).

const (
	appleIssuer    = "https://appleid.apple.com"
	appleAuthURL   = appleIssuer + "/auth/authorize"
	appleTokenURL  = appleIssuer + "/auth/token"
	appleRevokeURL = appleIssuer + "/auth/revoke"
	appleKeysURL   = appleIssuer + "/auth/keys"

	// appleCookiePath scopes oauth.go's round-trip cookie to this flow alone.
	appleCookiePath = apiPrefix + "/auth/apple"
	// appleCallbackPath is the one /v1 write Apple's own site posts to.
	appleCallbackPath = appleCookiePath + "/callback"

	// appleClientSecretTTL is how long each client secret is good for. Apple allows six
	// months; one is signed per request, so minutes are plenty.
	appleClientSecretTTL = 5 * time.Minute
)

// AppleOAuthConfig is what cmd/holdmytrack hands New — config.Config's Apple* values. An empty
// ServicesID means the feature is off; an empty BundleID turns off only the native endpoint.
type AppleOAuthConfig struct {
	ServicesID  string
	BundleID    string
	TeamID      string
	KeyID       string
	PrivateKey  *ecdsa.PrivateKey
	RedirectURL string
}

// appleOAuth is AppleOAuthConfig plus what a test needs to swap out: Apple's endpoints, the
// HTTP client that reaches them, and the keys its notifications are signed with.
type appleOAuth struct {
	AppleOAuthConfig
	tokenURL  string
	revokeURL string
	client    *http.Client
	keys      *jwksKeySet
}

func newAppleOAuth(cfg AppleOAuthConfig) appleOAuth {
	client := &http.Client{Timeout: 10 * time.Second}
	return appleOAuth{AppleOAuthConfig: cfg, tokenURL: appleTokenURL, revokeURL: appleRevokeURL, client: client, keys: newJWKSKeySet(appleKeysURL, client)}
}

func (a appleOAuth) enabled() bool { return a.ServicesID != "" && a.PrivateKey != nil }

// handleAppleStart serves `GET /v1/auth/apple/start?tz=<IANA name>` — a full-page navigation,
// as handleGoogleStart is. No PKCE: Apple's web flow doesn't document it, and the code is only
// redeemable with a client secret signed by a key that never leaves this server; state still
// ties the callback to this browser. A native app adds `&app_challenge=` as for Google (oauth.go).
func (s *Server) handleAppleStart(w http.ResponseWriter, r *http.Request) {
	if !s.apple.enabled() {
		writeAPIError(w, "not found", http.StatusNotFound)
		return
	}
	state, _, ok := s.beginOAuth(w, r, appleCookiePath, false)
	if !ok {
		return
	}
	q := url.Values{
		"client_id":     {s.apple.ServicesID},
		"redirect_uri":  {s.apple.RedirectURL},
		"response_type": {"code"},
		"response_mode": {"form_post"},
		"scope":         {"name email"},
		"state":         {state},
	}
	http.Redirect(w, r, appleAuthURL+"?"+q.Encode(), http.StatusFound)
}

// handleAppleCallback serves `POST /v1/auth/apple/callback` — Apple's form post back. Every
// failure redirects to `/signin?error=apple` (or back to the app, for a round trip it started),
// with the detail in the log.
func (s *Server) handleAppleCallback(w http.ResponseWriter, r *http.Request) {
	if !s.apple.enabled() {
		writeAPIError(w, "not found", http.StatusNotFound)
		return
	}
	rt, err := s.readOAuthCallback(w, r, appleCookiePath)
	fail := func(msg string, err error) {
		s.log.Warn("apple sign-in failed: "+msg, "err", err)
		s.failOAuth(w, r, rt, "apple")
	}
	if err != nil {
		fail("callback", err)
		return
	}
	ctx := r.Context()
	tok, err := s.exchangeAppleCode(ctx, s.apple.ServicesID, rt.code, s.apple.RedirectURL)
	if err != nil {
		fail("code exchange", err)
		return
	}
	userID, err := s.signInApple(ctx, tok, s.apple.ServicesID, appleFormName(r.PostFormValue("user")), rt.tz)
	if err != nil {
		fail("account resolution", err)
		return
	}
	if err := s.finishOAuth(w, r, rt, userID); err != nil {
		fail("session start", err)
	}
}

// handleAppleToken serves `POST /v1/auth/apple/token` `{authorization_code, name, tz}` — Sign
// in with Apple for the iOS app (docs/IMPLEMENTATION.md §4.9). The app gets the code from
// AuthenticationServices and posts it here; the code is exchanged under the bundle ID, which
// checks it with Apple and returns the refresh token the web flow keeps too. The platform hands
// the app the name only on the first authorization, so the app sends it. The answer is the same
// session JSON as a password sign-in; every failure is a 401 with the web's wording.
func (s *Server) handleAppleToken(w http.ResponseWriter, r *http.Request) {
	if !s.apple.enabled() || s.apple.BundleID == "" {
		writeAPIError(w, "not found", http.StatusNotFound)
		return
	}
	var req struct {
		AuthorizationCode string `json:"authorization_code"`
		Name              string `json:"name"`
		TZ                string `json:"tz"`
	}
	if err := decodeJSON(r.Body, &req); err != nil {
		writeAPIError(w, bodyError(err, "invalid JSON body"), http.StatusBadRequest)
		return
	}
	fail := func(msg string, err error) {
		s.log.Warn("apple sign-in failed: "+msg, "err", err)
		writeError(w, http.StatusUnauthorized, "apple_failed", i18n.Get(requestLang(r)).T("signin.apple_failed"))
	}
	ctx := r.Context()
	tok, err := s.exchangeAppleCode(ctx, s.apple.BundleID, req.AuthorizationCode, "")
	if err != nil {
		fail("code exchange", err)
		return
	}
	tz, _ := normalizeTimezone(req.TZ)
	userID, err := s.signInApple(ctx, tok, s.apple.BundleID, req.Name, tz)
	if err != nil {
		fail("account resolution", err)
		return
	}
	s.writeSession(w, r, userID, sessionTTL, http.StatusOK)
}

// signInApple resolves the account for tokens exchanged under clientID and keeps the refresh
// token with the link, replacing an older one.
func (s *Server) signInApple(ctx context.Context, tok appleTokens, clientID, name, tz string) (string, error) {
	userID, err := s.resolveVerifiedUser(ctx, "apple", tok.claims.Sub, tok.claims.Email, name, tz)
	if err != nil {
		return "", err
	}
	if tok.refreshToken != "" {
		if _, err := s.pool.Exec(ctx, `
			UPDATE user_identities SET refresh_token = $1, client_id = $2 WHERE provider = 'apple' AND subject = $3
		`, tok.refreshToken, clientID, tok.claims.Sub); err != nil {
			return "", err
		}
	}
	return userID, nil
}

// appleFormName is the name in the callback's `user` field, which Apple sends only on a
// person's first authorization: `{"name":{"firstName":…,"lastName":…},"email":…}`.
func appleFormName(user string) string {
	var u struct {
		Name struct {
			FirstName string `json:"firstName"`
			LastName  string `json:"lastName"`
		} `json:"name"`
	}
	if json.Unmarshal([]byte(user), &u) != nil {
		return ""
	}
	return strings.TrimSpace(u.Name.FirstName + " " + u.Name.LastName)
}

// appleClaims is the subset of Apple's id_token payload this flow reads.
type appleClaims struct {
	Iss   string `json:"iss"`
	Aud   string `json:"aud"`
	Exp   int64  `json:"exp"`
	Sub   string `json:"sub"`
	Email string `json:"email"`
	// Apple has sent both the string "true" and a JSON boolean.
	EmailVerified any `json:"email_verified"`
}

// appleTokens is what Apple's token endpoint answers a code with.
type appleTokens struct {
	claims       appleClaims
	refreshToken string
}

// exchangeAppleCode trades an authorization code issued to clientID for tokens. The id_token
// comes straight from Apple's token endpoint over TLS, so, as for Google, its claims are checked
// and its signature isn't (OpenID Connect Core §3.1.3.7). redirectURI is empty for a code an app
// got from the platform.
func (s *Server) exchangeAppleCode(ctx context.Context, clientID, code, redirectURI string) (appleTokens, error) {
	if code == "" {
		return appleTokens{}, errors.New("no code")
	}
	secret, err := appleClientSecret(s.apple.AppleOAuthConfig, clientID, time.Now())
	if err != nil {
		return appleTokens{}, err
	}
	form := url.Values{
		"client_id":     {clientID},
		"client_secret": {secret},
		"code":          {code},
		"grant_type":    {"authorization_code"},
	}
	if redirectURI != "" {
		form.Set("redirect_uri", redirectURI)
	}
	body, err := s.applePost(ctx, s.apple.tokenURL, form)
	if err != nil {
		return appleTokens{}, err
	}
	var tok struct {
		IDToken      string `json:"id_token"`
		RefreshToken string `json:"refresh_token"`
	}
	if err := json.Unmarshal(body, &tok); err != nil {
		return appleTokens{}, fmt.Errorf("token response: %w", err)
	}
	claims, err := parseAppleIDToken(tok.IDToken, clientID, time.Now())
	if err != nil {
		return appleTokens{}, err
	}
	return appleTokens{claims: claims, refreshToken: tok.RefreshToken}, nil
}

// applePost posts form to one of Apple's endpoints and returns a 200's body.
func (s *Server) applePost(ctx context.Context, endpoint string, form url.Values) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := s.apple.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s returned %d: %s", endpoint, resp.StatusCode, body)
	}
	return body, nil
}

// parseAppleIDToken decodes an id_token's payload and checks its issuer, audience, expiry and
// subject, and that it carries an email Apple has verified: the email is what an existing
// account gets linked by. A Hide My Email relay address is verified like any other.
func parseAppleIDToken(idToken, clientID string, now time.Time) (appleClaims, error) {
	segs := strings.Split(idToken, ".")
	if len(segs) != 3 {
		return appleClaims{}, errors.New("id_token is not a JWT")
	}
	payload, err := base64.RawURLEncoding.DecodeString(segs[1])
	if err != nil {
		return appleClaims{}, fmt.Errorf("id_token payload: %w", err)
	}
	var c appleClaims
	if err := json.Unmarshal(payload, &c); err != nil {
		return appleClaims{}, fmt.Errorf("id_token payload: %w", err)
	}
	switch {
	case c.Iss != appleIssuer:
		return appleClaims{}, fmt.Errorf("unexpected issuer %q", c.Iss)
	case c.Aud != clientID:
		return appleClaims{}, fmt.Errorf("unexpected audience %q", c.Aud)
	case now.Unix() >= c.Exp:
		return appleClaims{}, errors.New("id_token expired")
	case c.Sub == "":
		return appleClaims{}, errors.New("id_token has no subject")
	case c.EmailVerified != true && c.EmailVerified != "true":
		return appleClaims{}, errors.New("apple account email is not verified")
	}
	email, err := normalizeEmail(c.Email)
	if err != nil {
		return appleClaims{}, err
	}
	c.Email = email
	return c, nil
}

// appleClientSecret signs the JWT Apple takes as the client secret for clientID: ES256 with the
// Sign in with Apple key, issued by the team, for Apple's audience.
func appleClientSecret(cfg AppleOAuthConfig, clientID string, now time.Time) (string, error) {
	enc := base64.RawURLEncoding.EncodeToString
	header, err := json.Marshal(map[string]string{"alg": "ES256", "kid": cfg.KeyID})
	if err != nil {
		return "", err
	}
	claims, err := json.Marshal(map[string]any{
		"iss": cfg.TeamID,
		"iat": now.Unix(),
		"exp": now.Add(appleClientSecretTTL).Unix(),
		"aud": appleIssuer,
		"sub": clientID,
	})
	if err != nil {
		return "", err
	}
	signingInput := enc(header) + "." + enc(claims)
	digest := sha256.Sum256([]byte(signingInput))
	r, sv, err := ecdsa.Sign(rand.Reader, cfg.PrivateKey, digest[:])
	if err != nil {
		return "", err
	}
	// A JWT's ES256 signature is r and s as two 32-byte big-endian numbers, not ASN.1.
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	sv.FillBytes(sig[32:])
	return signingInput + "." + enc(sig), nil
}
