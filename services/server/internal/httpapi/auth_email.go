package httpapi

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"
	"golang.org/x/crypto/bcrypt"

	"github.com/HoldMyTrack/platform/services/server/internal/i18n"
)

// The flows an email finishes: password reset by its link, and email verification and changing
// the account's address by its code (verify_code.go).

type forgotPasswordRequest struct {
	Email string `json:"email"`
}

// handleForgotPassword serves `POST /v2/auth/forgot-password`. Always responds 200 with the
// same generic body whether or not the email matches a real, claimed account — the same
// "don't leak which emails are registered" reasoning handleLogin already applies; a failure
// sending the actual email isn't surfaced to the caller either, for the same reason. Rate
// limited per IP like handleDemoStart: the other endpoint reachable with no credentials at
// all that has a real-world side effect (sending mail) a script could otherwise abuse.
func (s *Server) handleForgotPassword(w http.ResponseWriter, r *http.Request) {
	var req forgotPasswordRequest
	if err := decodeJSON(r.Body, &req); err != nil {
		writeAPIError(w, bodyError(err, "invalid request body"), http.StatusBadRequest)
		return
	}
	send, err := s.requestPasswordReset(r, req.Email)
	if err != nil {
		s.writeAccountError(w, r, "forgot-password", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{
		"message": i18n.Get(requestLang(r)).T("message.reset_sent"),
	})
	s.afterResponse(send)
}

// requestPasswordReset is the forgot-password core (the JSON endpoint and the /forgot page).
// It only ever fails on the rate limit or a malformed address. Everything that depends on
// whether the address has an account, the lookup, the link and the mail, is in send, which the
// caller hands to afterResponse: an unknown email, and a failure sending, both look like
// success, in what is answered and in how long it takes. A flushed answer isn't enough: one
// with no Content-Length goes chunked, and its end follows the handler's return.
func (s *Server) requestPasswordReset(r *http.Request, rawEmail string) (send func(), err error) {
	if !forgotPasswordLimiter.allow(rateLimitAddress(r)) {
		return nil, accountFailure(http.StatusTooManyRequests, "error.rate_limited")
	}
	email, err := normalizeEmail(rawEmail)
	if err != nil {
		return nil, err
	}
	return func() {
		if err := s.sendPasswordReset(r.WithContext(context.WithoutCancel(r.Context())), email); err != nil {
			s.log.Error("forgot-password failed", "err", err)
		}
	}, nil
}

// sendPasswordReset looks up a real, claimed account — one with a password or a linked external
// identity (a Google- or Facebook-only account sets its first password this way, docs/SPEC.md FR-1.5);
// excludes the unclaimed placeholder row and demo accounts, whose email is an internal
// placeholder nobody can type in anyway — and, if one exists, creates a token and emails the reset link. A no-op
// for an unmatched email: handleForgotPassword responds the same way either way, so there is
// nothing to report back here except a genuine infrastructure failure. The email is in the
// account's own language, or, when it has none set, the language of the request asking.
func (s *Server) sendPasswordReset(r *http.Request, email string) error {
	ctx := r.Context()
	var userID, locale string
	err := s.pool.QueryRow(ctx, `
		SELECT id, COALESCE(locale, '') FROM users
		WHERE email = $1 AND id <> $2 AND (password_hash IS NOT NULL OR EXISTS (SELECT 1 FROM user_identities i WHERE i.user_id = users.id))
	`, email, DemoCustomerUserID).Scan(&userID, &locale)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}

	expiresAt := time.Now().Add(passwordResetTTL)
	tokenID, hash := newToken()
	if _, err := s.pool.Exec(ctx,
		`INSERT INTO password_resets (token_hash, user_id, expires_at) VALUES ($1, $2, $3)`,
		hash, userID, expiresAt,
	); err != nil {
		return err
	}

	link := fmt.Sprintf("%s/reset?token=%s", s.appBaseURL, tokenID)
	l := i18n.Get(i18n.Resolve(locale, r))
	return s.mailer.Send(ctx, email, l.T("email.reset.subject"), l.T("email.reset.body", "link", link))
}

type resetPasswordRequest struct {
	Token    string `json:"token"`
	Password string `json:"password"`
}

// handleResetPassword serves `POST /v2/auth/reset-password`. A generic error for a missing or
// expired token, same reasoning as everywhere else here — distinguishing "no such token" from
// "expired" would tell a caller more than it needs to know. On success: sets the new password,
// retires every outstanding reset token for the account (not just the one used — a reset
// should close every other still-live link too), ends every existing session (this is exactly
// the moment an already-compromised one should stop working), and starts a fresh one for the
// browser completing the reset, same as signup/login already do.
func (s *Server) handleResetPassword(w http.ResponseWriter, r *http.Request) {
	var req resetPasswordRequest
	if err := decodeJSON(r.Body, &req); err != nil {
		writeAPIError(w, bodyError(err, "invalid request body"), http.StatusBadRequest)
		return
	}
	userID, err := s.resetPassword(r.Context(), req.Token, req.Password)
	if err != nil {
		s.writeAccountError(w, r, "reset-password", err)
		return
	}
	s.writeSession(w, r, userID, sessionTTL, http.StatusOK)
}

// resetPassword is the reset core (the JSON endpoint and the /reset page): sets the new
// password and returns the account id, for the caller to start the fresh session. One
// transaction, so a reset that can't end the old ways in changes nothing.
func (s *Server) resetPassword(ctx context.Context, token, password string) (string, error) {
	if err := checkPasswordLength(password); err != nil {
		return "", err
	}
	// The token is checked before the hash, so a guessed one costs no bcrypt, and again under
	// the lock below.
	var live bool
	if err := s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM password_resets WHERE token_hash = $1 AND expires_at > NOW())`, tokenHash(token)).Scan(&live); err != nil {
		return "", err
	}
	if !live {
		return "", accountFailure(http.StatusBadRequest, "error.reset_link_invalid")
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return "", err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return "", err
	}
	defer tx.Rollback(ctx) //nolint:errcheck // no-op once committed

	var userID string
	var verified bool
	err = tx.QueryRow(ctx, `
		SELECT r.user_id, u.email_verified FROM password_resets r JOIN users u ON u.id = r.user_id
		WHERE r.token_hash = $1 AND r.expires_at > NOW()
		FOR UPDATE OF u
	`, tokenHash(token)).Scan(&userID, &verified)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", accountFailure(http.StatusBadRequest, "error.reset_link_invalid")
	}
	if err != nil {
		return "", err
	}
	// A reset proves who holds the mailbox. An unverified account's Facebook link proves
	// nothing about the address, so whoever linked it loses it (ADR-0009).
	if !verified {
		if _, err := tx.Exec(ctx, `DELETE FROM user_identities WHERE user_id = $1 AND provider = 'facebook'`, userID); err != nil {
			return "", err
		}
	}
	if _, err := tx.Exec(ctx, `UPDATE users SET password_hash = $2 WHERE id = $1`, userID, hash); err != nil {
		return "", err
	}
	if err := endSignIns(ctx, tx, userID); err != nil {
		return "", err
	}
	return userID, tx.Commit(ctx)
}

// forgotPasswordLimiter mirrors demoLimiter — 5 requests per hour per address is generous for
// someone genuinely locked out (a reset link stays usable for an hour, so retrying the
// request itself should be rare) and cheap to hit for a script trying to mail-bomb an
// arbitrary address through this endpoint.
var forgotPasswordLimiter = newFixedWindowLimiter(5, time.Hour)

// applyVerification makes email the verified address of userID, whose row the caller holds
// locked in tx: current is the address before, wasVerified
// whether it was verified, and keep the hash of the one session a first verification leaves.
func applyVerification(ctx context.Context, tx pgx.Tx, userID, email, current string, wasVerified bool, keep []byte) error {
	if _, err := tx.Exec(ctx, `UPDATE users SET email = $2, email_verified = true WHERE id = $1`, userID, email); err != nil {
		if isUniqueViolation(err) {
			// Another account took the address while this change was pending.
			return accountFailure(http.StatusConflict, "error.email_taken")
		}
		return err
	}
	// Every outstanding row for this account, not just the newest: an older one would keep
	// holding its address against other accounts (changeEmail).
	if _, err := tx.Exec(ctx, `DELETE FROM email_verifications WHERE user_id = $1`, userID); err != nil {
		return err
	}
	// A reset link mailed to the address the account just left must stop working with it.
	if email != current {
		if _, err := tx.Exec(ctx, `DELETE FROM password_resets WHERE user_id = $1`, userID); err != nil {
			return err
		}
	}
	if !wasVerified {
		if _, err := tx.Exec(ctx, `DELETE FROM sessions WHERE user_id = $1 AND token_hash <> $2`, userID, keep); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `DELETE FROM auth_handoffs WHERE user_id = $1`, userID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `DELETE FROM export_links WHERE export_id IN (SELECT id FROM exports WHERE user_id = $1)`, userID); err != nil {
			return err
		}
	}
	return nil
}

// pendingEmail is the address the account's newest live verification email went to — a
// pending change's new address, or the account's own — falling back to the account's
// address when none is outstanding. It's where a resend goes, and what /verify-pending
// says it sent a code to.
func (s *Server) pendingEmail(ctx context.Context, userID string) (string, error) {
	var email string
	err := s.pool.QueryRow(ctx, `
		SELECT COALESCE(
			(SELECT email FROM email_verifications WHERE user_id = $1 AND expires_at > NOW() ORDER BY created_at DESC LIMIT 1),
			(SELECT email FROM users WHERE id = $1))
	`, userID).Scan(&email)
	return email, err
}

// handleResendVerification serves `POST /v2/auth/resend-verification` — plain requireAuth,
// deliberately not requireVerified, since the whole point is helping an account that hasn't
// verified yet. Rate-limited per account rather than per IP (resendVerificationLimiter): the
// caller is already an authenticated user at this point, not an anonymous one, so the abuse
// case this guards is one signed-in account spamming its own inbox, not a script targeting
// arbitrary addresses.
func (s *Server) handleResendVerification(w http.ResponseWriter, r *http.Request) {
	info := authInfoFromContext(r.Context())
	if info.emailVerified && !info.isDemo {
		writeJSON(w, http.StatusOK, map[string]string{"message": i18n.Get(requestLang(r)).T("message.already_verified")})
		return
	}
	if err := s.resendVerification(r.Context(), info, requestLang(r)); err != nil {
		s.writeAccountError(w, r, "resend verification", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"message": i18n.Get(requestLang(r)).T("message.verification_sent")})
}

// resendVerification is the resend core (the JSON endpoint and the /verify-pending page). lang
// is the email's language.
func (s *Server) resendVerification(ctx context.Context, info authInfo, lang string) error {
	if info.isDemo {
		return accountFailure(http.StatusBadRequest, "error.demo_no_email_verify")
	}
	if !resendVerificationLimiter.allow(info.userID) {
		return accountFailure(http.StatusTooManyRequests, "error.rate_limited")
	}
	email, err := s.pendingEmail(ctx, info.userID)
	if err != nil {
		return err
	}
	return s.sendVerificationEmail(ctx, info.userID, email, lang)
}

// resendVerificationLimiter mirrors forgotPasswordLimiter's shape but keys on the account's
// own id rather than an IP — see handleResendVerification's own doc comment for why.
var resendVerificationLimiter = newFixedWindowLimiter(5, time.Hour)

type changeEmailRequest struct {
	Email string `json:"email"`
}

// handleChangeEmail serves `PATCH /v2/auth/email` — plain requireAuth like
// handleResendVerification, reachable before verification specifically so a mistyped signup
// email can be corrected: resending alone doesn't help someone who typed the address wrong.
// The change is pending until the code sent to the new address is typed (changeEmail); the
// response is the account as it stands meanwhile.
func (s *Server) handleChangeEmail(w http.ResponseWriter, r *http.Request) {
	info := authInfoFromContext(r.Context())
	var req changeEmailRequest
	if err := decodeJSON(r.Body, &req); err != nil {
		writeAPIError(w, bodyError(err, "invalid request body"), http.StatusBadRequest)
		return
	}
	if err := s.changeEmail(r.Context(), info, req.Email, requestLang(r)); err != nil {
		s.writeAccountError(w, r, "change-email", err)
		return
	}
	resp, err := s.loadAuthResponse(r.Context(), info.userID)
	if err != nil {
		s.log.Error("change-email response lookup failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

// changeEmail is the change-email core (the JSON endpoint and the /verify-pending page). lang
// is the verification email's language.
//
// The new address is not the account's until the code sent there is typed (verifyCode applies
// it); the account keeps its current address, and its verified state,
// meanwhile. Applied at once, any account could take an address nobody had proven: the real
// owner couldn't sign up with it, and a password reset by them would hand them an account
// whose Google or Facebook sign-in still belonged to whoever made the change. Rate-limited
// with resends, since each call mails an address of the caller's choosing.
func (s *Server) changeEmail(ctx context.Context, info authInfo, rawEmail, lang string) error {
	if info.isDemo {
		return accountFailure(http.StatusBadRequest, "error.demo_no_email_change")
	}
	email, err := normalizeEmail(rawEmail)
	if err != nil {
		return err
	}
	var taken, pending bool
	if err := s.pool.QueryRow(ctx, `
		SELECT EXISTS (SELECT 1 FROM users WHERE email = $1 AND id <> $2),
		       EXISTS (SELECT 1 FROM email_verifications WHERE email = $1 AND user_id <> $2 AND expires_at > NOW())
	`, email, info.userID).Scan(&taken, &pending); err != nil {
		return err
	}
	if taken {
		return accountFailure(http.StatusConflict, "error.email_taken")
	}
	// One account at a time confirms an address: each would have a code of its own to guess at,
	// and another account's change waits until that one's row expires (emailVerificationTTL).
	if pending {
		return accountFailure(http.StatusConflict, "error.email_pending")
	}
	if !resendVerificationLimiter.allow(info.userID) {
		return accountFailure(http.StatusTooManyRequests, "error.rate_limited")
	}
	// One pending address at a time: a code sent before this change, to either address,
	// stops working.
	if _, err := s.pool.Exec(ctx, `DELETE FROM email_verifications WHERE user_id = $1`, info.userID); err != nil {
		return err
	}
	if err := s.sendVerificationEmail(ctx, info.userID, email, lang); err != nil {
		s.log.Error("change-email verification send failed", "err", err)
	}
	return nil
}
