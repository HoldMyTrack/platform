package httpapi

import (
	"context"
	"errors"
	"net/http"

	"github.com/jackc/pgx/v5"
)

// The verification link's page. Opening the link confirms the address only in a browser already
// signed in to the link's account; anywhere else the page shows a button that posts the token.
// Mail security scanners open every link in a message, so a link that confirmed on opening let
// them confirm addresses nobody had read, such as those a script signs up with.

// verifyLink is what opening a verification link found, read without changing anything.
type verifyLink struct {
	// Live: the token names an unexpired link of an account not deleted.
	Live bool
	// Own: the browser is signed in to that account.
	Own bool
	// Error is the ?error= a Facebook round trip this page started comes back with
	// (finishFacebookVerify, failOAuth).
	Error string
}

// verifyPage decides what opening a link does: confirm now, or show the page with form at
// status. A browser signed in to the link's account confirms at once, which is also how a
// Facebook round trip from this page finishes.
func verifyPage(token string, link verifyLink, facebook bool) (confirm bool, form authForm, status int) {
	if token == "" || !link.Live {
		return false, authForm{ErrorKey: "error.verify_link_invalid"}, http.StatusBadRequest
	}
	if link.Own {
		return true, authForm{}, 0
	}
	switch link.Error {
	case "other_facebook":
		return false, authForm{Token: token, Facebook: facebook, ErrorKey: "error.verify_other_facebook"}, http.StatusForbidden
	case "facebook":
		return false, authForm{Token: token, Facebook: facebook, ErrorKey: "signin.facebook_failed"}, http.StatusForbidden
	}
	return false, authForm{Token: token, Confirm: true}, http.StatusOK
}

// lookUpVerifyLink reads whether token is a live link and whether sessionID is signed in to its
// account, with the same conditions verifyEmail applies.
func (s *Server) lookUpVerifyLink(ctx context.Context, token, sessionID string) (verifyLink, error) {
	var link verifyLink
	err := s.pool.QueryRow(ctx, `
		SELECT true, EXISTS (SELECT 1 FROM sessions WHERE user_id = ev.user_id AND token_hash = $2 AND expires_at > NOW())
		FROM email_verifications ev JOIN users u ON u.id = ev.user_id
		WHERE ev.token_hash = $1 AND ev.expires_at > NOW() AND u.deleted_at IS NULL
	`, tokenHash(token), tokenHash(sessionID)).Scan(&link.Live, &link.Own)
	if errors.Is(err, pgx.ErrNoRows) {
		return verifyLink{}, nil
	}
	return link, err
}

// GET /verify?token= — the link in the verification email.
func (s *Server) handleVerifyPage(w http.ResponseWriter, r *http.Request) {
	sessionID, _ := sessionIDFromRequest(r)
	token := r.URL.Query().Get("token")
	var link verifyLink
	if token != "" {
		var err error
		if link, err = s.lookUpVerifyLink(r.Context(), token, sessionID); err != nil {
			acct, ok := s.pageAccount(w, r)
			if !ok {
				return
			}
			s.renderAuthError(w, r, acct, "verify link", "verify", "verify.title", true, authForm{Token: token, Confirm: true}, err)
			return
		}
		link.Error = r.URL.Query().Get("error")
	}
	confirm, form, status := verifyPage(token, link, s.facebook.enabled())
	if confirm {
		s.confirmVerifyLink(w, r, token, sessionID)
		return
	}
	acct, ok := s.pageAccount(w, r)
	if !ok {
		return
	}
	s.renderAuth(w, r, acct, status, "verify", "verify.title", true, form)
}

// POST /verify — the page's button.
func (s *Server) handleVerifyForm(w http.ResponseWriter, r *http.Request) {
	sessionID, _ := sessionIDFromRequest(r)
	s.confirmVerifyLink(w, r, r.PostFormValue("token"), sessionID)
}

// confirmVerifyLink confirms the link's address (verifyEmail). The token works once, so a second
// press finds it used: the message for that says a confirmed email just signs in. A browser
// signed in to the link's account goes on with the session it has; any other, signed out or
// signed in to another account, keeps what it has and is sent to sign in.
func (s *Server) confirmVerifyLink(w http.ResponseWriter, r *http.Request, token, sessionID string) {
	_, signIn, err := s.verifyEmail(r.Context(), token, sessionID)
	if err != nil {
		acct, ok := s.pageAccount(w, r)
		if !ok {
			return
		}
		s.renderAuthError(w, r, acct, "verify email", "verify", "verify.title", true, verifyFailureForm(token, err, s.facebook.enabled()), err)
		return
	}
	if !signIn {
		http.Redirect(w, r, "/signin?verified", http.StatusSeeOther)
		return
	}
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

// verifyFailureForm is the page after confirming failed: a Facebook-linked account's way in, no
// button for a refusal pressing again can't change, and the button again after an internal
// error, which rolled back and left the link usable.
func verifyFailureForm(token string, err error, facebook bool) authForm {
	if errors.Is(err, errVerifyNeedsFacebook) {
		return authForm{Token: token, Facebook: facebook}
	}
	var ae *accountError
	if errors.As(err, &ae) {
		return authForm{}
	}
	return authForm{Token: token, Confirm: true}
}
