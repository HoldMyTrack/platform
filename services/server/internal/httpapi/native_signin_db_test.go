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
	d.decode(d.do(account{}, "POST", "/v1/auth/handoff", map[string]string{"code": code, "verifier": verifier}), http.StatusOK, &got)
	if got.Token == "" {
		t.Fatal("no session token")
	}
	if rec := d.do(account{}, "POST", "/v1/auth/handoff", map[string]string{"code": code, "verifier": verifier}); rec.Code != http.StatusUnauthorized {
		t.Fatalf("second use: status %d, want 401", rec.Code)
	}
}

func TestGoogleTokenStartsSession(t *testing.T) {
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
	var got struct {
		Token string `json:"session_token"`
	}
	d.decode(d.do(account{}, "POST", "/v1/auth/google/token", map[string]string{"id_token": token, "tz": "Europe/Berlin"}), http.StatusOK, &got)
	if got.Token == "" {
		t.Fatal("no session token")
	}
}
