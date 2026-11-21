package httpapi

import (
	"context"
	"crypto/rsa"
	"fmt"
	"net/http"
	"testing"
	"time"
)

// The Android app's two ways to a session end in the same answer as a password sign-in; these
// check that answer against the contract for each.

func TestAuthHandoffStartsSession(t *testing.T) {
	d := newDBTest(t)
	me := d.newAccount(false)
	verifier := "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8" // 32 bytes, base64url: PKCE's 43 characters
	code, err := d.srv.createHandoff(context.Background(), me.id, testChallenge(verifier))
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		Token string `json:"session_token"`
	}
	d.decode(d.do(account{}, "POST", "/v2/auth/handoff", map[string]string{"code": code, "verifier": verifier}), http.StatusOK, &got)
	if got.Token == "" {
		t.Fatal("no session token")
	}
	if rec := d.do(account{}, "POST", "/v2/auth/handoff", map[string]string{"code": code, "verifier": verifier}); rec.Code != http.StatusUnauthorized {
		t.Fatalf("second use: status %d, want 401", rec.Code)
	}
}

// A token without a nonce is refused: every build MIN_ANDROID_BUILD lets in asks for one, so a
// token without it was copied from somewhere.
func TestGoogleTokenWithoutNonceIsRefused(t *testing.T) {
	d := newDBTest(t)
	key := newRSAKey(t)
	certs := &fakeCerts{keys: map[string]*rsa.PublicKey{"k1": &key.PublicKey}}
	d.srv.google = testGoogleKeyServer(certs.serve(t).URL).google

	now := time.Now()
	claims := validClaims(now)
	claims["sub"] = fmt.Sprintf("test-%d", now.UnixNano())
	email := fmt.Sprintf("google-%d@holdmytrack.invalid", now.UnixNano())
	claims["email"] = email
	t.Cleanup(func() {
		if _, err := d.pool.Exec(context.Background(), `DELETE FROM users WHERE email = $1`, email); err != nil {
			t.Errorf("delete account: %v", err)
		}
	})
	token := signedIDToken(t, key, map[string]string{"alg": "RS256", "kid": "k1"}, claims)
	if rec := d.do(account{}, "POST", "/v2/auth/google/token", map[string]string{"id_token": token, "tz": "Europe/Berlin"}); rec.Code != http.StatusUnauthorized {
		t.Fatalf("a token without a nonce: status %d, want 401", rec.Code)
	}
}

// A token carrying the app's nonce signs in once: the nonce is spent, so the same token posted
// again, from a log or anywhere else, is refused, as is one with a nonce the server never issued.
func TestGoogleTokenSpendsNonce(t *testing.T) {
	d := newDBTest(t)
	if rec := d.do(account{}, "POST", "/v2/auth/google/nonce", nil); rec.Code != http.StatusNotFound {
		t.Fatalf("Google not configured: status %d", rec.Code)
	}
	key := newRSAKey(t)
	certs := &fakeCerts{keys: map[string]*rsa.PublicKey{"k1": &key.PublicKey}}
	d.srv.google = testGoogleKeyServer(certs.serve(t).URL).google

	var issued struct {
		Nonce string `json:"nonce"`
	}
	d.decode(d.do(account{}, "POST", "/v2/auth/google/nonce", nil), http.StatusCreated, &issued)
	now := time.Now()
	claims := validClaims(now)
	claims["sub"] = fmt.Sprintf("test-%d", now.UnixNano())
	email := fmt.Sprintf("google-%d@holdmytrack.invalid", now.UnixNano())
	claims["email"] = email
	claims["nonce"] = issued.Nonce
	t.Cleanup(func() {
		if _, err := d.pool.Exec(context.Background(), `DELETE FROM users WHERE email = $1`, email); err != nil {
			t.Errorf("delete account: %v", err)
		}
	})
	token := signedIDToken(t, key, map[string]string{"alg": "RS256", "kid": "k1"}, claims)
	post := func(token string) int {
		return d.do(account{}, "POST", "/v2/auth/google/token", map[string]string{"id_token": token, "tz": "Europe/Berlin"}).Code
	}
	if code := post(token); code != http.StatusOK {
		t.Fatalf("first post: status %d", code)
	}
	if code := post(token); code != http.StatusUnauthorized {
		t.Errorf("the same token again: status %d, want 401", code)
	}
	claims["nonce"] = "00000000-0000-4000-8000-000000000000"
	if code := post(signedIDToken(t, key, map[string]string{"alg": "RS256", "kid": "k1"}, claims)); code != http.StatusUnauthorized {
		t.Errorf("a nonce never issued: status %d, want 401", code)
	}

	d.srv.googleNonceLimiter = newFixedWindowLimiter(1, time.Hour)
	d.do(account{}, "POST", "/v2/auth/google/nonce", nil)
	if rec := d.do(account{}, "POST", "/v2/auth/google/nonce", nil); rec.Code != http.StatusTooManyRequests {
		t.Errorf("past the address's limit: status %d, want 429", rec.Code)
	}
}
