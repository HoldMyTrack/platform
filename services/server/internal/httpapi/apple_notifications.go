package httpapi

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"time"
)

// handleAppleNotifications serves `POST /v1/auth/apple/notifications` `{payload}` — Apple's
// server-to-server notifications about Sign in with Apple (docs/SPEC.md FR-1.14), at the URL
// registered on the App ID. The payload is a JWT Apple signs with the keys it publishes. When
// someone stops using Sign in with Apple here, or deletes their Apple ID, the link is removed
// and the account's sessions end; the account stays, reachable through its email. Other events
// change nothing.
func (s *Server) handleAppleNotifications(w http.ResponseWriter, r *http.Request) {
	if !s.apple.enabled() {
		writeAPIError(w, "not found", http.StatusNotFound)
		return
	}
	var req struct {
		Payload string `json:"payload"`
	}
	if err := decodeJSON(r.Body, &req); err != nil {
		writeAPIError(w, bodyError(err, "invalid JSON body"), http.StatusBadRequest)
		return
	}
	event, err := s.parseAppleNotification(r, req.Payload)
	if err != nil {
		s.log.Warn("apple notification refused", "err", err)
		writeAPIError(w, "invalid payload", http.StatusBadRequest)
		return
	}
	switch event.Type {
	case "consent-revoked", "account-delete":
		if err := s.unlinkApple(r, event.Sub); err != nil {
			s.log.Error("apple unlink failed", "err", err)
			writeAPIError(w, "internal error", http.StatusInternalServerError)
			return
		}
	}
	w.WriteHeader(http.StatusOK)
}

// appleEvent is a notification's one event.
type appleEvent struct {
	Type string `json:"type"`
	Sub  string `json:"sub"`
}

// parseAppleNotification checks a notification's signature, issuer and audience — one of this
// deployment's two client ids — and returns its event, which Apple sends as a JSON string.
func (s *Server) parseAppleNotification(r *http.Request, payload string) (appleEvent, error) {
	raw, err := verifyRS256(r.Context(), s.apple.keys, payload, time.Now())
	if err != nil {
		return appleEvent{}, err
	}
	var c struct {
		Iss    string `json:"iss"`
		Aud    string `json:"aud"`
		Events string `json:"events"`
	}
	if err := json.Unmarshal(raw, &c); err != nil {
		return appleEvent{}, fmt.Errorf("payload: %w", err)
	}
	if c.Iss != appleIssuer {
		return appleEvent{}, fmt.Errorf("unexpected issuer %q", c.Iss)
	}
	if c.Aud == "" || (c.Aud != s.apple.ServicesID && c.Aud != s.apple.BundleID) {
		return appleEvent{}, fmt.Errorf("unexpected audience %q", c.Aud)
	}
	var e appleEvent
	if err := json.Unmarshal([]byte(c.Events), &e); err != nil {
		return appleEvent{}, fmt.Errorf("events: %w", err)
	}
	if e.Sub == "" {
		return appleEvent{}, errors.New("event has no subject")
	}
	return e, nil
}

// unlinkApple removes the Apple link with subject and ends its account's sessions, in one
// transaction. A subject linked to nothing here is no error.
func (s *Server) unlinkApple(r *http.Request, subject string) error {
	ctx := r.Context()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `
		WITH gone AS (DELETE FROM user_identities WHERE provider = 'apple' AND subject = $1 RETURNING user_id)
		DELETE FROM sessions WHERE user_id IN (SELECT user_id FROM gone)
	`, subject); err != nil {
		return err
	}
	return tx.Commit(ctx)
}
