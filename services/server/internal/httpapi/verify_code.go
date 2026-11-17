package httpapi

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// A verification email carries a 6-digit code beside its link, typed where the account is signed
// in: the apps' "check your email" screens and /verify-pending. A code proves the mailbox to the
// session that types it, so that session stays signed in, where a link opened in a browser
// signs out every session but one already signed in there (verifyEmail). Only the newest
// email's code works; it lives verificationCodeTTL and allows verificationCodeTries wrong tries,
// and a resend, limited with address changes, sends a new one. Wrong tries are also limited per
// address across accounts (codeTriesPerAddress), since each account guessing at one address has
// a code of its own.

const (
	verificationCodeTTL   = 30 * time.Minute
	verificationCodeTries = 5
)

// codeTriesPerAddress counts wrong codes per address being verified, whichever account typed
// them. Ten an hour make guessing an address's codes take years; the cost is that someone
// burning them holds the owner's code off for the rest of the hour.
var codeTriesPerAddress = newFixedWindowLimiter(10, time.Hour)

// newVerificationCode is a fresh code: six digits, every value equally likely.
func newVerificationCode() (string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(1_000_000))
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%06d", n.Int64()), nil
}

// verificationCodeHash is what a row keeps of its code, bound to the row's link so the same code
// in two rows hashes differently.
func verificationCodeHash(linkHash []byte, code string) []byte {
	h := sha256.New()
	h.Write(linkHash)
	h.Write([]byte(code))
	return h.Sum(nil)
}

// normalizeVerificationCode is the code typed, without the spaces or dashes someone copying it
// might bring; ok is false unless six digits remain.
func normalizeVerificationCode(raw string) (code string, ok bool) {
	code = strings.Map(func(r rune) rune {
		if r == ' ' || r == '-' || r == ' ' {
			return -1
		}
		return r
	}, strings.TrimSpace(raw))
	if len(code) != 6 {
		return "", false
	}
	for _, r := range code {
		if r < '0' || r > '9' {
			return "", false
		}
	}
	return code, true
}

// codeVerdict is what typing a code does.
type codeVerdict int

const (
	codeAccepted codeVerdict = iota
	// codeWrong leaves tries for the same code.
	codeWrong
	// codeUsedUp is a wrong code that was the last try: the code no longer works.
	codeUsedUp
	// codeExpired is a code past its time or its tries, or none at all.
	codeExpired
)

// checkVerificationCode decides a typed code for the newest email's code: live whether it
// exists and hasn't expired, attempts the wrong tries it has had, matches whether this one is it.
func checkVerificationCode(live bool, attempts int, matches bool) codeVerdict {
	switch {
	case !live || attempts >= verificationCodeTries:
		return codeExpired
	case matches:
		return codeAccepted
	case attempts+1 >= verificationCodeTries:
		return codeUsedUp
	default:
		return codeWrong
	}
}

// verifyCode is the code's core (the JSON endpoint and the /verify-pending page): info's account
// types raw from the session whose id is sessionID, which a first verification keeps.
func (s *Server) verifyCode(ctx context.Context, info authInfo, sessionID, raw string) error {
	if info.isDemo {
		return accountFailure(http.StatusBadRequest, "error.demo_no_email_verify")
	}
	code, ok := normalizeVerificationCode(raw)
	if !ok {
		return accountFailure(http.StatusBadRequest, "error.code_invalid")
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck // no-op once committed

	var linkHash, codeHash []byte
	var email, current string
	var live, wasVerified bool
	var attempts int
	err = tx.QueryRow(ctx, `
		SELECT ev.token_hash, ev.email, ev.code_hash, COALESCE(ev.code_expires_at > NOW(), false), ev.code_attempts,
		       u.email, u.email_verified
		FROM email_verifications ev JOIN users u ON u.id = ev.user_id
		WHERE ev.user_id = $1 AND u.deleted_at IS NULL
		ORDER BY ev.created_at DESC LIMIT 1
		FOR UPDATE OF u, ev
	`, info.userID).Scan(&linkHash, &email, &codeHash, &live, &attempts, &current, &wasVerified)
	if errors.Is(err, pgx.ErrNoRows) {
		return accountFailure(http.StatusBadRequest, "error.code_expired")
	}
	if err != nil {
		return err
	}
	if codeTriesPerAddress.full(email) {
		return accountFailure(http.StatusTooManyRequests, "error.code_rate_limited")
	}
	matches := codeHash != nil && subtle.ConstantTimeCompare(codeHash, verificationCodeHash(linkHash, code)) == 1
	verdict := checkVerificationCode(live && codeHash != nil, attempts, matches)
	switch verdict {
	case codeExpired:
		return accountFailure(http.StatusBadRequest, "error.code_expired")
	case codeWrong, codeUsedUp:
		codeTriesPerAddress.allow(email)
		if _, err := tx.Exec(ctx, `UPDATE email_verifications SET code_attempts = code_attempts + 1 WHERE token_hash = $1`, linkHash); err != nil {
			return err
		}
		if err := tx.Commit(ctx); err != nil {
			return err
		}
		if verdict == codeUsedUp {
			return accountFailure(http.StatusBadRequest, "error.code_used_up")
		}
		return accountFailure(http.StatusBadRequest, "error.code_wrong")
	}
	if err := applyVerification(ctx, tx, info.userID, email, current, wasVerified, tokenHash(sessionID)); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

type verifyCodeRequest struct {
	Code string `json:"code"`
}

// handleVerifyCode serves `POST /v1/auth/verify-code`, requireAuth like resend: the account as
// verified.
func (s *Server) handleVerifyCode(w http.ResponseWriter, r *http.Request) {
	info := authInfoFromContext(r.Context())
	var req verifyCodeRequest
	if err := decodeJSON(r.Body, &req); err != nil {
		writeAPIError(w, bodyError(err, "invalid request body"), http.StatusBadRequest)
		return
	}
	sessionID, _ := sessionIDFromRequest(r)
	if err := s.verifyCode(r.Context(), info, sessionID, req.Code); err != nil {
		s.writeAccountError(w, r, "verify code", err)
		return
	}
	resp, err := s.loadAuthResponse(r.Context(), info.userID)
	if err != nil {
		s.log.Error("verify-code response lookup failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

// POST /verify-pending/code.
func (s *Server) handleVerifyCodeForm(w http.ResponseWriter, r *http.Request) {
	acct, ok := s.pageAccount(w, r)
	if !ok {
		return
	}
	if acct == nil {
		http.Redirect(w, r, "/signin", http.StatusSeeOther)
		return
	}
	sessionID, _ := sessionIDFromRequest(r)
	if err := s.verifyCode(r.Context(), acct.info, sessionID, r.PostFormValue("code")); err != nil {
		email, lookupErr := s.pendingEmail(r.Context(), acct.info.userID)
		if lookupErr != nil {
			email = acct.user.Email
		}
		s.renderAuthError(w, r, acct, "verify code", "verify-pending", "verify.title", true, authForm{Email: email}, err)
		return
	}
	http.Redirect(w, r, "/", http.StatusSeeOther)
}
