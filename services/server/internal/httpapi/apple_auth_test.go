package httpapi

// Covers docs/SPEC.md FR-1.14 (Sign in with Apple).

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log/slog"
	"math/big"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

const (
	testServicesID = "com.holdmytrack.web"
	testBundleID   = "dev.holdmytrack.ios"
)

func newAppleKey(t *testing.T) *ecdsa.PrivateKey {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return key
}

func testAppleConfig(t *testing.T) AppleOAuthConfig {
	return AppleOAuthConfig{
		ServicesID: testServicesID, BundleID: testBundleID, TeamID: "TEAM123456", KeyID: "KEY1234567",
		PrivateKey: newAppleKey(t), RedirectURL: "https://app.example/v1/auth/apple/callback",
	}
}

// testAppleServer is a Server with Sign in with Apple on, its token and revoke endpoints at
// appleURL + /auth/token and /auth/revoke when appleURL is set.
func testAppleServer(t *testing.T, appleURL string) *Server {
	a := newAppleOAuth(testAppleConfig(t))
	if appleURL != "" {
		a.tokenURL, a.revokeURL = appleURL+"/auth/token", appleURL+"/auth/revoke"
	}
	return &Server{log: slog.New(slog.DiscardHandler), appBaseURL: "https://app.example", apple: a}
}

func validAppleClaims(now time.Time, aud string) map[string]any {
	return map[string]any{
		"iss":            appleIssuer,
		"aud":            aud,
		"exp":            now.Add(time.Hour).Unix(),
		"sub":            "001234.abcdef.0987",
		"email":          " Someone@PrivateRelay.AppleID.com ",
		"email_verified": "true",
	}
}

func TestParseAppleIDToken(t *testing.T) {
	now := time.Now()
	c, err := parseAppleIDToken(fakeIDToken(t, validAppleClaims(now, testServicesID)), testServicesID, now)
	if err != nil {
		t.Fatalf("valid token rejected: %v", err)
	}
	if c.Sub != "001234.abcdef.0987" || c.Email != "someone@privaterelay.appleid.com" {
		t.Fatalf("unexpected claims: %+v", c)
	}
	boolVerified := validAppleClaims(now, testServicesID)
	boolVerified["email_verified"] = true
	if _, err := parseAppleIDToken(fakeIDToken(t, boolVerified), testServicesID, now); err != nil {
		t.Fatalf("boolean email_verified rejected: %v", err)
	}
	for name, mutate := range map[string]func(map[string]any){
		"wrong issuer":     func(c map[string]any) { c["iss"] = "https://accounts.google.com" },
		"wrong audience":   func(c map[string]any) { c["aud"] = testBundleID },
		"expired":          func(c map[string]any) { c["exp"] = now.Add(-time.Second).Unix() },
		"no subject":       func(c map[string]any) { delete(c, "sub") },
		"unverified email": func(c map[string]any) { c["email_verified"] = "false" },
		"no email":         func(c map[string]any) { delete(c, "email") },
	} {
		claims := validAppleClaims(now, testServicesID)
		mutate(claims)
		if _, err := parseAppleIDToken(fakeIDToken(t, claims), testServicesID, now); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestAppleClientSecret(t *testing.T) {
	cfg := testAppleConfig(t)
	now := time.Unix(1_800_000_000, 0)
	secret, err := appleClientSecret(cfg, testBundleID, now)
	if err != nil {
		t.Fatal(err)
	}
	segs := strings.Split(secret, ".")
	if len(segs) != 3 {
		t.Fatalf("not a JWT: %q", secret)
	}
	var header map[string]string
	var claims map[string]any
	for i, v := range []any{&header, &claims} {
		raw, err := base64.RawURLEncoding.DecodeString(segs[i])
		if err != nil || json.Unmarshal(raw, v) != nil {
			t.Fatalf("segment %d: %v", i, err)
		}
	}
	if header["alg"] != "ES256" || header["kid"] != cfg.KeyID {
		t.Fatalf("header %v", header)
	}
	if claims["iss"] != cfg.TeamID || claims["sub"] != testBundleID || claims["aud"] != appleIssuer ||
		claims["iat"] != float64(now.Unix()) || claims["exp"] != float64(now.Add(appleClientSecretTTL).Unix()) {
		t.Fatalf("claims %v", claims)
	}
	sig, err := base64.RawURLEncoding.DecodeString(segs[2])
	if err != nil || len(sig) != 64 {
		t.Fatalf("signature: %d bytes, %v", len(sig), err)
	}
	digest := sha256.Sum256([]byte(segs[0] + "." + segs[1]))
	if !ecdsa.Verify(&cfg.PrivateKey.PublicKey, digest[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])) {
		t.Fatal("signature does not verify")
	}
}

func TestAppleStartRedirectsToFormPost(t *testing.T) {
	s := testAppleServer(t, "")
	rec := serveChecked(t, s.handleAppleStart, httptest.NewRequest("GET", "/v1/auth/apple/start?tz=Europe/Berlin", nil))
	if rec.Code != http.StatusFound {
		t.Fatalf("status %d", rec.Code)
	}
	loc, err := url.Parse(rec.Header().Get("Location"))
	if err != nil || !strings.HasPrefix(loc.String(), appleAuthURL+"?") {
		t.Fatalf("bad redirect %q", rec.Header().Get("Location"))
	}
	q := loc.Query()
	if q.Get("client_id") != testServicesID || q.Get("response_mode") != "form_post" || q.Get("scope") != "name email" || q.Get("state") == "" {
		t.Fatalf("bad auth params: %v", q)
	}
	cookies := rec.Result().Cookies()
	if len(cookies) != 1 || cookies[0].Path != appleCookiePath || cookies[0].SameSite != http.SameSiteNoneMode || !cookies[0].Secure {
		t.Fatalf("bad oauth cookie: %+v", cookies)
	}
	if bad := serveChecked(t, s.handleAppleStart, httptest.NewRequest("GET", "/v1/auth/apple/start?app_challenge=short", nil)); bad.Code != http.StatusBadRequest {
		t.Fatalf("bad app_challenge: status %d", bad.Code)
	}
}

func TestAppleCookieLaxWithoutHTTPS(t *testing.T) {
	if got := oauthCookieSameSite(appleCookiePath, false); got != http.SameSiteLaxMode {
		t.Fatalf("got %v", got)
	}
	if got := oauthCookieSameSite(googleCookiePath, true); got != http.SameSiteLaxMode {
		t.Fatalf("google: got %v", got)
	}
}

func TestAppleEndpointsDisabledWithoutServicesID(t *testing.T) {
	s := &Server{log: slog.New(slog.DiscardHandler), apple: newAppleOAuth(AppleOAuthConfig{})}
	for _, req := range []*http.Request{
		httptest.NewRequest("GET", "/v1/auth/apple/start", nil),
		formRequest("/v1/auth/apple/callback", url.Values{}),
	} {
		h := s.handleAppleStart
		if req.Method == "POST" {
			h = s.handleAppleCallback
		}
		if rec := serveChecked(t, h, req); rec.Code != http.StatusNotFound {
			t.Errorf("%s %s: status %d, want 404", req.Method, req.URL.Path, rec.Code)
		}
	}
}

func formRequest(path string, form url.Values) *http.Request {
	req := httptest.NewRequest("POST", path, strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	return req
}

func TestAppleCallbackRejectsStateMismatch(t *testing.T) {
	s := testAppleServer(t, "")
	req := formRequest("/v1/auth/apple/callback", url.Values{"state": {"forged"}, "code": {"x"}})
	req.AddCookie(&http.Cookie{Name: oauthCookieName, Value: "real..UTC."})
	rec := serveChecked(t, s.handleAppleCallback, req)
	if loc := rec.Header().Get("Location"); rec.Code != http.StatusFound || loc != "https://app.example/signin?error=apple" {
		t.Fatalf("got %d %q", rec.Code, loc)
	}
}

func TestAppleCallbackPassesCrossSiteCheck(t *testing.T) {
	s := &Server{appBaseURL: "https://app.example"}
	for _, tc := range []struct {
		path, origin string
		refused      bool
	}{
		{appleCallbackPath, appleIssuer, false},
		{appleCallbackPath, "https://evil.example", true},
		{apiPrefix + "/auth/login", appleIssuer, true},
	} {
		req := httptest.NewRequest("POST", tc.path, nil)
		req.Header.Set("Origin", tc.origin)
		if got := s.crossSiteAPIWrite(req); got != tc.refused {
			t.Errorf("%s from %s: refused %v, want %v", tc.path, tc.origin, got, tc.refused)
		}
	}
}

func TestAppleFormName(t *testing.T) {
	for user, want := range map[string]string{
		`{"name":{"firstName":"Some","lastName":"One"},"email":"a@b.c"}`: "Some One",
		`{"name":{"firstName":"Some"}}`:                                  "Some",
		``:                                                               "",
		`not json`:                                                       "",
	} {
		if got := appleFormName(user); got != want {
			t.Errorf("%q: got %q, want %q", user, got, want)
		}
	}
}

// fakeApple stands in for appleid.apple.com's token and revoke endpoints, answering a code with
// an id_token for claims and recording each request's form.
type fakeApple struct {
	t       *testing.T
	claims  map[string]any
	token   []url.Values
	revoked []url.Values
}

func (f *fakeApple) serve() *httptest.Server {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.ParseForm()
		switch r.URL.Path {
		case "/auth/token":
			f.token = append(f.token, r.PostForm)
			if r.PostForm.Get("code") == "bad" {
				http.Error(w, `{"error":"invalid_grant"}`, http.StatusBadRequest)
				return
			}
			json.NewEncoder(w).Encode(map[string]string{"id_token": fakeIDToken(f.t, f.claims), "refresh_token": "refresh-" + r.PostForm.Get("code")})
		case "/auth/revoke":
			f.revoked = append(f.revoked, r.PostForm)
		default:
			http.NotFound(w, r)
		}
	}))
	f.t.Cleanup(srv.Close)
	return srv
}

func TestAppleCallbackSignsIn(t *testing.T) {
	d := newDBTest(t)
	now := time.Now()
	email := fmt.Sprintf("apple-%d@holdmytrack.invalid", now.UnixNano())
	t.Cleanup(func() {
		if _, err := d.pool.Exec(context.Background(), `DELETE FROM users WHERE email = $1`, email); err != nil {
			t.Errorf("delete account: %v", err)
		}
	})
	claims := validAppleClaims(now, testServicesID)
	claims["sub"], claims["email"] = fmt.Sprintf("apple-%d", now.UnixNano()), email
	apple := &fakeApple{t: t, claims: claims}
	d.srv.apple = testAppleServer(t, apple.serve().URL).apple

	start := httptest.NewRecorder()
	d.srv.ServeHTTP(start, httptest.NewRequest("GET", "/v1/auth/apple/start?tz=Europe/Berlin", nil))
	state, _ := url.Parse(start.Header().Get("Location"))
	form := url.Values{
		"state": {state.Query().Get("state")},
		"code":  {"the-code"},
		"user":  {`{"name":{"firstName":"Some","lastName":"One"}}`},
	}
	req := formRequest("/v1/auth/apple/callback", form)
	req.Header.Set("Origin", appleIssuer)
	req.AddCookie(start.Result().Cookies()[0])
	rec := httptest.NewRecorder()
	d.srv.ServeHTTP(rec, req)
	checkContract(t, req, []byte(form.Encode()), rec)

	if loc := rec.Header().Get("Location"); rec.Code != http.StatusFound || loc != "https://app.example/" {
		t.Fatalf("got %d %q", rec.Code, loc)
	}
	var session bool
	for _, c := range rec.Result().Cookies() {
		session = session || (c.Name == sessionCookieName && c.Value != "")
	}
	if !session {
		t.Fatal("no session cookie")
	}
	if len(apple.token) != 1 || apple.token[0].Get("client_id") != testServicesID || apple.token[0].Get("redirect_uri") == "" {
		t.Fatalf("token requests %v", apple.token)
	}
	var name, tz, refresh, client string
	if err := d.pool.QueryRow(context.Background(), `
		SELECT u.display_name, u.timezone, i.refresh_token, i.client_id
		FROM users u JOIN user_identities i ON i.user_id = u.id AND i.provider = 'apple'
		WHERE u.email = $1
	`, email).Scan(&name, &tz, &refresh, &client); err != nil {
		t.Fatal(err)
	}
	if name != "Some One" || tz != "Europe/Berlin" || refresh != "refresh-the-code" || client != testServicesID {
		t.Fatalf("got name %q, tz %q, refresh %q, client %q", name, tz, refresh, client)
	}
}

func TestAppleTokenStartsSession(t *testing.T) {
	d := newDBTest(t)
	now := time.Now()
	email := fmt.Sprintf("apple-ios-%d@holdmytrack.invalid", now.UnixNano())
	t.Cleanup(func() {
		if _, err := d.pool.Exec(context.Background(), `DELETE FROM users WHERE email = $1`, email); err != nil {
			t.Errorf("delete account: %v", err)
		}
	})
	claims := validAppleClaims(now, testBundleID)
	claims["sub"], claims["email"] = fmt.Sprintf("apple-ios-%d", now.UnixNano()), email
	apple := &fakeApple{t: t, claims: claims}
	d.srv.apple = testAppleServer(t, apple.serve().URL).apple

	var got struct {
		Token string `json:"session_token"`
	}
	d.decode(d.do(account{}, "POST", "/v1/auth/apple/token", map[string]string{"authorization_code": "ios-code", "name": "Some One", "tz": "Europe/Berlin"}), http.StatusOK, &got)
	if got.Token == "" {
		t.Fatal("no session token")
	}
	if len(apple.token) != 1 || apple.token[0].Get("client_id") != testBundleID || apple.token[0].Has("redirect_uri") {
		t.Fatalf("token requests %v", apple.token)
	}
	var name, client string
	if err := d.pool.QueryRow(context.Background(), `
		SELECT u.display_name, i.client_id FROM users u JOIN user_identities i ON i.user_id = u.id AND i.provider = 'apple' WHERE u.email = $1
	`, email).Scan(&name, &client); err != nil {
		t.Fatal(err)
	}
	if name != "Some One" || client != testBundleID {
		t.Fatalf("got name %q, client %q", name, client)
	}

	if rec := d.do(account{}, "POST", "/v1/auth/apple/token", map[string]string{"authorization_code": "bad"}); rec.Code != http.StatusUnauthorized || !strings.Contains(rec.Body.String(), "Apple") {
		t.Fatalf("refused code: %d %s", rec.Code, rec.Body.String())
	}
	if rec := d.send(account{}, "POST", "/v1/auth/apple/token", "application/json", []byte("{")); rec.Code != http.StatusBadRequest {
		t.Fatalf("bad body: %d", rec.Code)
	}
}

func TestAppleTokenNeedsBundleID(t *testing.T) {
	s := testAppleServer(t, "")
	s.apple.BundleID = ""
	rec := serveChecked(t, s.handleAppleToken, httptest.NewRequest("POST", "/v1/auth/apple/token", strings.NewReader(`{"authorization_code":"x"}`)))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status %d, want 404", rec.Code)
	}
}

// appleNotification is a notification body for event, RS256-signed with key under kid "k1".
func appleNotification(t *testing.T, key *rsa.PrivateKey, aud string, event map[string]any) map[string]string {
	t.Helper()
	events, err := json.Marshal(event)
	if err != nil {
		t.Fatal(err)
	}
	claims := map[string]any{"iss": appleIssuer, "aud": aud, "iat": time.Now().Unix(), "jti": "j1", "events": string(events)}
	return map[string]string{"payload": signedIDToken(t, key, map[string]string{"alg": "RS256", "kid": "k1"}, claims)}
}

func TestAppleNotificationsUnlink(t *testing.T) {
	d := newDBTest(t)
	ctx := context.Background()
	key, other := newRSAKey(t), newRSAKey(t)
	certs := &fakeCerts{keys: map[string]*rsa.PublicKey{"k1": &key.PublicKey}}
	d.srv.apple = testAppleServer(t, "").apple
	d.srv.apple.keys.url = certs.serve(t).URL

	me := d.newAccount(false)
	sub := fmt.Sprintf("apple-%d", time.Now().UnixNano())
	if _, err := d.pool.Exec(ctx, `INSERT INTO user_identities (user_id, provider, subject) VALUES ($1, 'apple', $2)`, me.id, sub); err != nil {
		t.Fatal(err)
	}
	links := func() (identities, sessions int) {
		if err := d.pool.QueryRow(ctx, `
			SELECT (SELECT count(*) FROM user_identities WHERE user_id = $1), (SELECT count(*) FROM sessions WHERE user_id = $1)
		`, me.id).Scan(&identities, &sessions); err != nil {
			t.Fatal(err)
		}
		return
	}

	for name, body := range map[string]map[string]string{
		"signed with another key": appleNotification(t, other, testServicesID, map[string]any{"type": "consent-revoked", "sub": sub}),
		"for another client":      appleNotification(t, key, "com.someone.else", map[string]any{"type": "consent-revoked", "sub": sub}),
	} {
		if rec := d.do(account{}, "POST", "/v1/auth/apple/notifications", body); rec.Code != http.StatusBadRequest {
			t.Fatalf("%s: status %d, want 400", name, rec.Code)
		}
	}
	if rec := d.do(account{}, "POST", "/v1/auth/apple/notifications", appleNotification(t, key, testBundleID, map[string]any{"type": "email-disabled", "sub": sub})); rec.Code != http.StatusOK {
		t.Fatalf("email-disabled: status %d", rec.Code)
	}
	if i, s := links(); i != 1 || s != 1 {
		t.Fatalf("before revoking: %d identities, %d sessions", i, s)
	}
	if rec := d.do(account{}, "POST", "/v1/auth/apple/notifications", appleNotification(t, key, testServicesID, map[string]any{"type": "consent-revoked", "sub": sub})); rec.Code != http.StatusOK {
		t.Fatalf("consent-revoked: status %d", rec.Code)
	}
	if i, s := links(); i != 0 || s != 0 {
		t.Fatalf("after revoking: %d identities, %d sessions", i, s)
	}
	var exists bool
	if err := d.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM users WHERE id = $1 AND deleted_at IS NULL)`, me.id).Scan(&exists); err != nil || !exists {
		t.Fatalf("account gone: %v", err)
	}
	if rec := d.do(account{}, "POST", "/v1/auth/apple/notifications", appleNotification(t, key, testServicesID, map[string]any{"type": "account-delete", "sub": "linked-to-nothing"})); rec.Code != http.StatusOK {
		t.Fatalf("unknown subject: status %d", rec.Code)
	}
}

func TestAppleNotificationsNeedApple(t *testing.T) {
	s := &Server{log: slog.New(slog.DiscardHandler), apple: newAppleOAuth(AppleOAuthConfig{})}
	rec := serveChecked(t, s.handleAppleNotifications, httptest.NewRequest("POST", "/v1/auth/apple/notifications", strings.NewReader(`{"payload":"a.b.c"}`)))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status %d, want 404", rec.Code)
	}
}

func TestDeleteAccountRevokesApple(t *testing.T) {
	d := newDBTest(t)
	ctx := context.Background()
	apple := &fakeApple{t: t}
	d.srv.apple = testAppleServer(t, apple.serve().URL).apple

	me := d.newAccount(false)
	if _, err := d.pool.Exec(ctx, `
		INSERT INTO user_identities (user_id, provider, subject, refresh_token, client_id) VALUES ($1, 'apple', $2, 'the-refresh-token', $3)
	`, me.id, fmt.Sprintf("apple-%d", time.Now().UnixNano()), testBundleID); err != nil {
		t.Fatal(err)
	}
	var email string
	if err := d.pool.QueryRow(ctx, `SELECT email FROM users WHERE id = $1`, me.id).Scan(&email); err != nil {
		t.Fatal(err)
	}
	if rec := d.do(me, "DELETE", "/v1/account", map[string]string{"email": email}); rec.Code != http.StatusNoContent {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	if len(apple.revoked) != 1 {
		t.Fatalf("%d revocations, want 1", len(apple.revoked))
	}
	got := apple.revoked[0]
	if got.Get("token") != "the-refresh-token" || got.Get("client_id") != testBundleID || got.Get("token_type_hint") != "refresh_token" || got.Get("client_secret") == "" {
		t.Fatalf("revoke request %v", got)
	}
}
