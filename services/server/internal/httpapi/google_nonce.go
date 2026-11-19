package httpapi

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"
)

// Sign in with Google on Android (docs/IMPLEMENTATION.md §4.9): the app asks for a nonce, has
// Credential Manager put it in the id_token, and posts the token. The token is accepted once,
// since redeeming deletes the nonce, so a copy of it, from a log or anywhere else, signs nobody
// in.

// googleNonceTTL bounds the gap between asking for a nonce and posting the token: the account
// picker and Google's consent.
const googleNonceTTL = 10 * time.Minute

// POST /v2/auth/google/nonce — a fresh nonce, googleNoncesPerHour an address. Expired ones
// nobody spent are purged here, so the table needs no sweeper.
func (s *Server) handleGoogleNonce(w http.ResponseWriter, r *http.Request) {
	if !s.google.enabled() {
		writeAPIError(w, "not found", http.StatusNotFound)
		return
	}
	if !s.googleNonceLimiter.allow(rateLimitAddress(r)) {
		httpErrorT(w, r, http.StatusTooManyRequests, "error.rate_limited")
		return
	}
	ctx := r.Context()
	nonce, hash := newToken()
	_, err := s.pool.Exec(ctx, `DELETE FROM google_nonces WHERE expires_at < NOW()`)
	if err == nil {
		_, err = s.pool.Exec(ctx, `INSERT INTO google_nonces (nonce_hash, expires_at) VALUES ($1, $2)`, hash, time.Now().Add(googleNonceTTL))
	}
	if err != nil {
		s.log.Error("google nonce failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"nonce": nonce})
}

// spendGoogleNonce deletes nonce, reporting an error when it was never issued, is spent or has
// expired.
func (s *Server) spendGoogleNonce(ctx context.Context, nonce string) error {
	var expiresAt time.Time
	err := s.pool.QueryRow(ctx, `DELETE FROM google_nonces WHERE nonce_hash = $1 RETURNING expires_at`, tokenHash(nonce)).Scan(&expiresAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return errors.New("unknown or spent nonce")
	}
	if err != nil {
		return err
	}
	if time.Now().After(expiresAt) {
		return errors.New("expired nonce")
	}
	return nil
}
