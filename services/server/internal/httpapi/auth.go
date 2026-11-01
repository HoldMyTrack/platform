package httpapi

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/mail"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"golang.org/x/crypto/bcrypt"

	"github.com/HoldMyTrack/platform/services/server/internal/i18n"
	"github.com/HoldMyTrack/platform/services/server/internal/web"
)

// Email+password auth, server-side sessions (migrations/0001_users_and_auth.sql) — resolved toward
// the smallest thing that removes the old placeholder-user stand-in, with no vendor to depend
// on, the same bias Path 3 uploads already made. Sign in with Google (google_auth.go) is an
// optional second way into the same accounts and the same sessions, off unless configured —
// email+password never depends on it. Password reset (IMPLEMENTATION.md §4.9) and email verification (docs/SPEC.md FR-1.8)
// share the same token-table shape. Rate limiting is partially built: see demoLimiter/forgotPasswordLimiter
// below, added specifically because their endpoints are reachable with no credentials at all,
// and storySendLimiter and Server.uploadLimiter, per account.

const sessionCookieName = "holdmytrack_session"

// sessionTTL is deliberately long — a single-user personal app with no "remember me"
// checkbox should just stay signed in, not force a re-login every few hours.
const sessionTTL = 30 * 24 * time.Hour

// demoSessionTTL bounds how long a no-signup demo session (VISION.md §8.2) stays signed in
// before needing a fresh `POST /v1/auth/demo` call — the persistent DemoCustomerUserID
// (demo_presets.go) it points at never itself expires or gets purged, only this session
// cookie does. Long enough to try the app and share a link same day.
const demoSessionTTL = 24 * time.Hour

// passwordResetTTL is deliberately much shorter than sessionTTL/demoSessionTTL — the
// industry-standard expectation for a reset link is short-lived, since it's usually emailed
// somewhere less secure than the session cookie it's standing in for.
const passwordResetTTL = time.Hour

// emailVerificationTTL is longer than passwordResetTTL — confirming a new signup is less
// time-sensitive than a credential reset, and someone might reasonably not check their inbox
// for a day.
const emailVerificationTTL = 24 * time.Hour

const minPasswordLength = 8

type authRequest struct {
	Email    string `json:"email"`
	Password string `json:"password"`
	// Optional — the browser's own Intl.DateTimeFormat().resolvedOptions().timeZone, sent
	// only by handleSignup's caller (decodeAuthRequest itself is shared with login, which
	// ignores this field). Invalid or absent falls back to "UTC" rather than rejecting the
	// signup over it — auto-detection is a convenience default, not something worth blocking
	// account creation over (users.timezone is always editable in Settings).
	Timezone string `json:"timezone"`
}

// normalizeTimezone validates raw against the IANA tz database via time.LoadLocation, and
// returns it under its current name (web.CurrentTimezoneName: a browser reports Asia/Calcutta,
// the account stores Asia/Kolkata). Returns ok=false for empty or unloadable input; the caller
// decides what that means for its own endpoint (createAccount falls back to "UTC",
// saveSettings rejects with a 400).
func normalizeTimezone(raw string) (tz string, ok bool) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", false
	}
	if _, err := time.LoadLocation(raw); err != nil {
		return "", false
	}
	return web.CurrentTimezoneName(raw), true
}

// authResponse is the one shape every auth endpoint and handleMe returns — see
// loadAuthResponse, the single place that builds one, for why every endpoint returns the
// full current profile rather than just whatever fields it happened to touch.
type authResponse struct {
	// Empty for a demo account — its email is an internal, never-shown placeholder (see
	// handleDemoStart), not something to leak into a response the frontend might display.
	Email  string `json:"email"`
	IsDemo bool   `json:"isDemo"`
	// Always true for a demo account (the gate never applies to one — see requireVerified);
	// for a real account, whatever users.email_verified actually holds. The frontend's own
	// gate logic still checks IsDemo itself rather than trusting this alone, so a demo session
	// is never accidentally read as "needs to verify."
	EmailVerified bool `json:"email_verified"`
	// The Settings page's own fields (services/server/internal/httpapi/account.go).
	// DisplayName/Country/AvatarURL are "" when unset — not omitted — so the frontend never
	// has to distinguish "absent" from "empty."
	DisplayName string `json:"display_name"`
	Country     string `json:"country"`
	AvatarURL   string `json:"avatar_url"`
	// IANA name (e.g. "America/New_York"), never empty — unlike DisplayName/Country there is
	// no "unset" state: the column is NOT NULL DEFAULT 'UTC' (migrations/0001_users_and_auth.sql).
	Timezone string `json:"timezone"`
	// Locale is the account's language (migrations/0001_users_and_auth.sql), "" for automatic —
	// the web app then follows the browser's.
	Locale string `json:"locale"`
}

// authResponseWithSession wraps authResponse with the freshly minted session id, for the
// four endpoints that call startSession and therefore have a session to hand back — signup,
// login, demo-start, reset-password. handleMe returns plain authResponse: it's "is my
// existing credential still valid," not a place to reissue one.
type authResponseWithSession struct {
	authResponse
	// SessionToken is the same value already set as the holdmytrack_session cookie in this same
	// response — a browser client can ignore this field entirely, it already has the
	// credential via Set-Cookie. A native client with no shared cookie jar (or one that needs
	// to inject the credential into MapLibre Native's own tile requests, which bypass the
	// app's own HTTP client — apps/android/docs/ARCHITECTURE.md §1's bearer-token
	// decision) stores this and sends it back as `Authorization: Bearer <SessionToken>`.
	SessionToken string `json:"session_token"`
}

// loadAuthResponse reads userID's current row and builds the shared authResponse shape —
// signup, login, demo-start and reset-password all call this instead of hand-building a
// response from just the fields they happened to already have, so a freshly created account
// reports its real column defaults (timezone, everything else unset) rather than
// a response that looks like every profile field was explicitly cleared.
func (s *Server) loadAuthResponse(ctx context.Context, userID string) (authResponse, error) {
	var email, displayName, country, avatarKey, timezone, locale string
	var avatarUpdatedAt *time.Time
	var emailVerified bool
	err := s.pool.QueryRow(ctx, `
		SELECT email, COALESCE(display_name, ''), COALESCE(country, ''),
		       COALESCE(avatar_key, ''), avatar_updated_at, email_verified, timezone, COALESCE(locale, '')
		FROM users WHERE id = $1
	`, userID).Scan(&email, &displayName, &country, &avatarKey, &avatarUpdatedAt, &emailVerified, &timezone, &locale)
	if err != nil {
		return authResponse{}, err
	}
	isDemo := userID == DemoCustomerUserID
	if isDemo {
		email = ""           // never leak the internal, synthetic demo email — see handleDemoStart
		emailVerified = true // the gate never applies to a demo account — see requireVerified
	}
	var avatarURL string
	if avatarKey != "" && avatarUpdatedAt != nil {
		// ?v= is a cache-busting param, not a real query param the endpoint reads — it just
		// needs to change whenever the underlying image does, so a browser that cached the
		// previous avatar at the old URL never mistakes it for the new one.
		avatarURL = fmt.Sprintf("/v1/account/avatar?v=%d", avatarUpdatedAt.Unix())
	}
	return authResponse{
		Email:         email,
		IsDemo:        isDemo,
		EmailVerified: emailVerified,
		DisplayName:   displayName,
		Country:       country,
		AvatarURL:     avatarURL,
		Timezone:      timezone,
		Locale:        locale,
	}, nil
}

func decodeAuthRequest(r *http.Request) (authRequest, error) {
	var req authRequest
	if err := decodeJSON(r.Body, &req); err != nil {
		return authRequest{}, errors.New(bodyError(err, "invalid request body"))
	}
	return req, nil
}

// validateCredentials is the email+password check signup and sign-in share, JSON or form:
// the normalized email, or a 400 accountFailure saying what's wrong.
func validateCredentials(rawEmail, password string) (string, error) {
	email, err := normalizeEmail(rawEmail)
	if err != nil {
		return "", err
	}
	if err := checkPasswordLength(password); err != nil {
		return "", err
	}
	return email, nil
}

// maxPasswordBytes is bcrypt's own input limit: GenerateFromPassword refuses anything longer,
// which surfaced as a 500 to someone pasting a password manager's long passphrase.
const maxPasswordBytes = 72

// checkPasswordLength is the length rule a new password (signup, reset) and a sign-in share.
func checkPasswordLength(password string) error {
	if len(password) < minPasswordLength {
		return accountFailure(http.StatusBadRequest, "error.password_too_short", "min", minPasswordLength)
	}
	if len(password) > maxPasswordBytes {
		return accountFailure(http.StatusBadRequest, "error.password_too_long", "max", maxPasswordBytes)
	}
	return nil
}

// accountError is a failure the person should see — wrong password, a taken email, an expired
// link — as opposed to an infrastructure error, which is logged and shown only as "internal
// error". The account cores above return one; the JSON handlers turn it into a status and
// plain-text body (writeAccountError), the pages into a message on the form (auth_pages.go).
//
// Its message is a catalog key (i18n) and that message's arguments, so each caller shows it in
// its own language: the page's, or the JSON request's (requestLang).
type accountError struct {
	status int
	key    string
	args   []any
}

func (e *accountError) Error() string { return i18n.Get(i18n.Default).T(e.key, e.args...) }

// message is the error's message in lang.
func (e *accountError) message(lang string) string { return i18n.Get(lang).T(e.key, e.args...) }

func accountFailure(status int, key string, args ...any) error {
	return &accountError{status: status, key: key, args: args}
}

// requestLang is the language a JSON request's messages are in: the signed-in account's own
// setting (requireAuth's authInfo), else the request's Accept-Language — which the web app
// sets to the language it shows — else English.
func requestLang(r *http.Request) string {
	return i18n.Resolve(authInfoFromContext(r.Context()).locale, r)
}

// writeAccountError is the JSON side of an account core's error: its own status, code and
// message (in the request's language) for an accountError, a logged 500 for anything else.
func (s *Server) writeAccountError(w http.ResponseWriter, r *http.Request, op string, err error) {
	var ae *accountError
	if errors.As(err, &ae) {
		writeAccountFailure(w, r, ae)
		return
	}
	s.log.Error(op+" failed", "err", err)
	writeAPIError(w, "internal error", http.StatusInternalServerError)
}

// writeSession starts a session for userID and answers with the account plus its token —
// what every JSON endpoint that signs someone in (signup, login, demo, reset, verify) returns.
func (s *Server) writeSession(w http.ResponseWriter, r *http.Request, userID string, ttl time.Duration, status int) {
	sessionID, err := s.startSession(w, r.Context(), userID, ttl)
	if err != nil {
		s.log.Error("session start failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	resp, err := s.loadAuthResponse(r.Context(), userID)
	if err != nil {
		s.log.Error("session response lookup failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	writeJSON(w, status, authResponseWithSession{authResponse: resp, SessionToken: sessionID})
}

// normalizeEmail is decodeAuthRequest's own validation, pulled out so handleForgotPassword
// (which has no password field to validate alongside it) can reuse it without duplicating
// the trim/lowercase/parse sequence.
//
// Only a bare address is accepted. mail.ParseAddress also takes "Name <a@b.c>", "<a@b.c>" and
// "a@b.c (comment)", which stored as typed let one mailbox register several times under the
// email-unique index (and the Google/Facebook email matching built on it), and then failed as
// an SMTP recipient, so the account could never be verified or reset.
func normalizeEmail(raw string) (string, error) {
	email := strings.TrimSpace(strings.ToLower(raw))
	addr, err := mail.ParseAddress(email)
	if err != nil || addr.Name != "" || addr.Address != email {
		return "", accountFailure(http.StatusBadRequest, "error.invalid_email")
	}
	return email, nil
}

var errEmailTaken = errors.New("email already registered")

// handleSignup serves `POST /v1/auth/signup`. Always a plain new account, whether or not the
// caller currently holds a demo session — docs/ROADMAP.md's "Email verification + demo
// without real ingest" retired the old claim-the-demo-account-in-place path along with demo's
// real upload/sync access: every demo session shares the one persistent DemoCustomerUserID
// (demo_presets.go) rather than holding a row of its own, so there is nothing per-session to
// preserve by reusing it. The new account starts unverified (email_verified defaults false) and
// gets a verification email; requireVerified is what actually gates on that.
func (s *Server) handleSignup(w http.ResponseWriter, r *http.Request) {
	req, err := decodeAuthRequest(r)
	if err != nil {
		writeAPIError(w, err.Error(), http.StatusBadRequest)
		return
	}
	userID, err := s.createAccountLimited(r, req.Email, req.Password, req.Timezone, requestLang(r))
	if err != nil {
		s.writeAccountError(w, r, "signup", err)
		return
	}
	s.writeSession(w, r, userID, sessionTTL, http.StatusCreated)
}

// createAccountLimited is createAccount within the address's signup limit
// (defaultSignupsPerHour), which only an account created counts.
func (s *Server) createAccountLimited(r *http.Request, email, password, timezone, lang string) (string, error) {
	ip := clientIP(r)
	if s.signupLimiter.exceeded(ip) {
		return "", accountFailure(http.StatusTooManyRequests, "error.signup_rate_limited")
	}
	userID, err := s.createAccount(r.Context(), email, password, timezone, lang)
	if err == nil {
		s.signupLimiter.hit(ip)
	}
	return userID, err
}

// createAccount is signup's shared core — handleSignup (JSON) and the /signup page
// (auth_pages.go) both call it. email and password are validated here, not by the caller.
// timezone is the browser's own guess and falls back to "UTC" when absent or unknown, rather
// than failing the signup over a convenience default (migrations/0001_users_and_auth.sql).
func (s *Server) createAccount(ctx context.Context, rawEmail, password, timezone, lang string) (string, error) {
	email, err := validateCredentials(rawEmail, password)
	if err != nil {
		return "", err
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return "", err
	}
	tz, ok := normalizeTimezone(timezone)
	if !ok {
		tz = "UTC"
	}
	var userID string
	err = s.pool.QueryRow(ctx,
		`INSERT INTO users (email, password_hash, email_verified, timezone) VALUES ($1, $2, $3, $4) RETURNING id`,
		email, hash, s.skipEmailVerification, tz,
	).Scan(&userID)
	if isUniqueViolation(err) {
		return "", accountFailure(http.StatusConflict, "error.email_taken")
	}
	if err != nil {
		return "", err
	}
	if !s.skipEmailVerification {
		if err := s.sendVerificationEmail(ctx, userID, email, lang); err != nil {
			// Not fatal to the signup itself — the account exists and can request a resend
			// (resendVerification) — but worth knowing about if Mailgun/SMTP is down.
			s.log.Error("verification email failed", "err", err)
		}
	}
	return userID, nil
}

// sendVerificationEmail creates a fresh token and emails the verification link — called from
// handleSignup, handleChangeEmail, and handleResendVerification, the three places a real
// account needs one (re)sent. lang is the language the email is written in.
func (s *Server) sendVerificationEmail(ctx context.Context, userID, email, lang string) error {
	expiresAt := time.Now().Add(emailVerificationTTL)
	tokenID, hash := newToken()
	if _, err := s.pool.Exec(ctx,
		`INSERT INTO email_verifications (token_hash, user_id, email, expires_at) VALUES ($1, $2, $3, $4)`,
		hash, userID, email, expiresAt,
	); err != nil {
		return err
	}

	link := fmt.Sprintf("%s/verify?token=%s", s.appBaseURL, tokenID)
	l := i18n.Get(lang)
	return s.mailer.Send(ctx, email, l.T("email.verify.subject"), l.T("email.verify.body", "link", link))
}

// handleLogin serves `POST /v1/auth/login`.
func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	req, err := decodeAuthRequest(r)
	if err != nil {
		writeAPIError(w, err.Error(), http.StatusBadRequest)
		return
	}
	userID, err := s.checkPassword(r.Context(), clientIP(r), req.Email, req.Password)
	if err != nil {
		s.writeAccountError(w, r, "login", err)
		return
	}
	s.writeSession(w, r, userID, sessionTTL, http.StatusOK)
}

// checkPassword is sign-in's shared core (handleLogin and the /signin page): the account id
// for a matching email and password. One generic failure whether the email doesn't exist,
// belongs to an unclaimed seed row (password_hash still NULL), or the password just doesn't
// match — distinguishing any of those would tell a caller which emails are registered.
//
// Failed attempts are limited per email and per caller address (signInFailureLimits), and a
// limited caller is refused before the password is checked, so guessing a password costs
// more than bcrypt's own time. Each attempt takes its slot before the check and gives it back
// on success: checked first and counted after, a burst of parallel guesses would all pass the
// check while the first were still comparing.
func (s *Server) checkPassword(ctx context.Context, ip, rawEmail, password string) (string, error) {
	email, err := validateCredentials(rawEmail, password)
	if err != nil {
		return "", err
	}
	if !signInFailuresByEmail.allow(email) {
		return "", accountFailure(http.StatusTooManyRequests, "error.rate_limited")
	}
	if !signInFailuresByIP.allow(ip) {
		signInFailuresByEmail.refund(email)
		return "", accountFailure(http.StatusTooManyRequests, "error.rate_limited")
	}
	notFailure := func() {
		signInFailuresByEmail.refund(email)
		signInFailuresByIP.refund(ip)
	}
	var userID string
	var hash []byte
	err = s.pool.QueryRow(ctx, `SELECT id, password_hash FROM users WHERE email = $1`, email).Scan(&userID, &hash)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		notFailure()
		return "", err
	}
	if !passwordMatches(hash, password) {
		return "", accountFailure(http.StatusUnauthorized, "error.invalid_credentials")
	}
	notFailure()
	return userID, nil
}

// passwordMatches reports whether password matches hash. A nil hash (no such email, or a row
// with no password) is compared against dummyPasswordHash and fails, so a caller can't tell a
// registered email from the time an answer takes.
func passwordMatches(hash []byte, password string) bool {
	if hash == nil {
		bcrypt.CompareHashAndPassword(dummyPasswordHash(), []byte(password)) //nolint:errcheck // timing only
		return false
	}
	return bcrypt.CompareHashAndPassword(hash, []byte(password)) == nil
}

var dummyPasswordHash = sync.OnceValue(func() []byte {
	hash, err := bcrypt.GenerateFromPassword([]byte("not anyone's password"), bcrypt.DefaultCost)
	if err != nil {
		panic(err)
	}
	return hash
})

// signInFailuresByEmail and signInFailuresByIP count failed sign-ins (checkPassword). Per
// email, 10 in 15 minutes: guessing one account's password from many addresses stays at
// about a thousand tries a day, and its owner, locked out of password sign-in at worst for 15
// minutes, still has Forgot password and Google/Facebook. Per address, 50 in 15 minutes:
// enough for a household behind one address, not for trying many accounts' passwords.
var (
	signInFailuresByEmail = newFixedWindowLimiter(10, 15*time.Minute)
	signInFailuresByIP    = newFixedWindowLimiter(50, 15*time.Minute)
)

// handleLogout serves `POST /v1/auth/logout` — deletes the session server-side (not just
// clearing the cookie), so a captured-but-not-yet-expired token stops working immediately.
// Reads the session id via sessionIDFromRequest (cookie or bearer token), not r.Cookie
// directly, so a mobile caller presenting only Authorization: Bearer actually revokes its
// session here instead of this silently no-op'ing and clearing a cookie that was never set.
func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	s.endSession(w, r)
	w.WriteHeader(http.StatusNoContent)
}

// endSession deletes the caller's session row and clears its cookie — shared by the JSON
// logout above and the pages' Sign out form (pages.go's handleLogoutPage).
func (s *Server) endSession(w http.ResponseWriter, r *http.Request) {
	if sessionID, ok := sessionIDFromRequest(r); ok {
		if _, err := s.pool.Exec(r.Context(), `DELETE FROM sessions WHERE token_hash = $1`, tokenHash(sessionID)); err != nil {
			s.log.Error("session delete failed", "err", err)
		}
	}
	http.SetCookie(w, &http.Cookie{
		Name:     sessionCookieName,
		Value:    "",
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		MaxAge:   -1,
	})
}

// handleMe serves `GET /v1/auth/me` — how the frontend learns whether a session cookie it's
// already holding is still valid, and whose it is, on first load (App.tsx).
func (s *Server) handleMe(w http.ResponseWriter, r *http.Request) {
	userID, ok := s.currentUserID(r)
	if !ok {
		writeAPIError(w, "not signed in", http.StatusUnauthorized)
		return
	}
	resp, err := s.loadAuthResponse(r.Context(), userID)
	if err != nil {
		s.log.Error("me lookup failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

// handleDemoStart serves `POST /v1/auth/demo`, VISION.md §8.2's no-signup look around: a
// session on the one shared, pre-seeded DemoCustomerUserID (demo_presets.go), read-only
// (requireNotDemo). One shared row rather than one per visitor, which would re-ingest the demo's
// whole history each time; handleSignup never reuses it, so a demo account can't become a real
// one in place. Rate-limited per address, being reachable with no credentials at all.
func (s *Server) handleDemoStart(w http.ResponseWriter, r *http.Request) {
	if err := allowDemo(r); err != nil {
		s.writeAccountError(w, r, "demo start", err)
		return
	}
	s.writeSession(w, r, DemoCustomerUserID, demoSessionTTL, http.StatusCreated)
}

// allowDemo is the demo start's one check, shared with the page's `POST /demo`.
func allowDemo(r *http.Request) error {
	if !demoLimiter.allow(clientIP(r)) {
		return accountFailure(http.StatusTooManyRequests, "error.demo_rate_limited")
	}
	return nil
}

// demoLimiter caps how many demo accounts one address can create — 5 per hour is generous
// for a real visitor trying the app (one demo session covers a whole session's uploads) and
// cheap to hit for anything scripted, without pulling in a rate-limiting library for the one
// endpoint that needs it.
var demoLimiter = newFixedWindowLimiter(5, time.Hour)
