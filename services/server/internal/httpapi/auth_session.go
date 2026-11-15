package httpapi

import (
	"context"
	"crypto/sha256"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/HoldMyTrack/platform/services/server/internal/zoneinfo"
)

// startSession returns the new session id, alongside setting it as the holdmytrack_session
// cookie. A browser needs nothing more; writeSession also hands the id back as
// authResponseWithSession.SessionToken, the bearer token of a native client with no
// browser-style cookie handling (apps/android/docs/ARCHITECTURE.md §1).
func (s *Server) startSession(w http.ResponseWriter, ctx context.Context, userID string, ttl time.Duration) (string, error) {
	expiresAt := time.Now().Add(ttl)
	sessionID, hash := newToken()
	if _, err := s.pool.Exec(ctx,
		`INSERT INTO sessions (token_hash, user_id, expires_at) VALUES ($1, $2, $3)`,
		hash, userID, expiresAt,
	); err != nil {
		return "", err
	}
	http.SetCookie(w, &http.Cookie{
		Name:     sessionCookieName,
		Value:    sessionID,
		Path:     "/",
		HttpOnly: true,
		// Derived from APP_BASE_URL rather than a separate env var — that's already the one
		// place this server is told whether it's serving over HTTPS (it's also what a
		// password-reset link is built from, sendPasswordReset). Local dev's default
		// ("http://localhost:5173") keeps this false, matching the plain-HTTP dev server;
		// the deploy runbook (docs/DEPLOY.md) sets a real https:// APP_BASE_URL in
		// production, which is what flips this on.
		Secure:   strings.HasPrefix(s.appBaseURL, "https://"),
		SameSite: http.SameSiteLaxMode,
		Expires:  expiresAt,
	})
	return sessionID, nil
}

// newToken makes the secret for a session, password reset, email verification or app handoff,
// and the SHA-256 its row keeps in its place (tokenHash), so a copy of the database or a backup
// holds nothing that signs in. A random UUID, the shape the clients and links already carry.
func newToken() (token string, hash []byte) {
	token = uuid.NewString()
	return token, tokenHash(token)
}

func tokenHash(token string) []byte {
	sum := sha256.Sum256([]byte(token))
	return sum[:]
}

// bearerPrefix is RFC 6750's scheme name for the Authorization header value —
// sessionIDFromRequest strips exactly this before treating the remainder as a session id.
const bearerPrefix = "Bearer "

// sessionIDFromRequest reads the session id a caller presented: the holdmytrack_session cookie
// for a browser (checked first — the long-established, higher-volume path), falling back to
// `Authorization: Bearer <session-id>` for a native client. This is not a second credential
// system — it's the same session token, just presented a second way, because a mobile
// app needs to inject it into MapLibre Native's own tile requests via a per-request header
// hook (apps/android/docs/ARCHITECTURE.md §1's bearer-token decision), which a cookie
// sitting in the app's own cookie jar wouldn't reach.
func sessionIDFromRequest(r *http.Request) (string, bool) {
	if cookie, err := r.Cookie(sessionCookieName); err == nil && cookie.Value != "" {
		return cookie.Value, true
	}
	if auth := r.Header.Get("Authorization"); strings.HasPrefix(auth, bearerPrefix) {
		if token := strings.TrimPrefix(auth, bearerPrefix); token != "" {
			return token, true
		}
	}
	return "", false
}

// currentUserID resolves the caller's session id (sessionIDFromRequest) to a user id, or
// ("", false) if there is none, or it doesn't match a live session. Expiry is checked in SQL
// (expires_at > NOW()), not left to the browser dropping an expired cookie on its own — a
// client could replay an old one past its stated expiry.
//
// err is a failed lookup, not a missing session: a caller answers it 503, never 401, since a
// client takes a 401 for a dead session and signs out.
func (s *Server) currentUserID(r *http.Request) (userID string, ok bool, err error) {
	info, _, found, err := s.lookupSession(r)
	return info.userID, found, err
}

// lookupSession is the one session lookup currentUserID, requireAuth and pageAccount share:
// the account behind r's session and when each client last used it, found false for no live
// session. err is a failed lookup, which every caller answers 503: a 401, or a page drawn
// signed out, would tell a client its session is gone when it isn't.
func (s *Server) lookupSession(r *http.Request) (info authInfo, was seen, found bool, err error) {
	sessionID, ok := sessionIDFromRequest(r)
	if !ok {
		return authInfo{}, seen{}, false, nil
	}
	err = s.pool.QueryRow(r.Context(), `
		SELECT u.id, u.email_verified, u.timezone, COALESCE(u.locale, ''), u.is_admin, u.last_seen_at,
		       u.web_seen_at, u.android_seen_at, u.android_build, u.ios_seen_at, u.ios_build
		FROM sessions se JOIN users u ON u.id = se.user_id
		WHERE se.token_hash = $1 AND se.expires_at > NOW()
	`, tokenHash(sessionID)).Scan(&info.userID, &info.emailVerified, &info.timezone, &info.locale, &info.isAdmin,
		&was.last, &was.web, &was.android, &was.androidBuild, &was.ios, &was.iosBuild)
	if errors.Is(err, pgx.ErrNoRows) {
		return authInfo{}, seen{}, false, nil
	}
	if err != nil {
		return authInfo{}, seen{}, false, err
	}
	info.isDemo = info.userID == DemoCustomerUserID
	return info, was, true, nil
}

type contextKey string

const authContextKey contextKey = "authInfo"

// authInfo is what requireAuth resolves a session to, in one query, and attaches to the request
// context: isDemo and emailVerified for the gates layered on top (requireVerified,
// requireNotDemo), timezone for day-bucketing without a second query, and locale for the
// language of a request's messages (requestLang), "" when the account follows its browser.
// isAdmin is read only by pageAccount, for the admin pages (admin_pages.go): no JSON endpoint is
// admin-only.
type authInfo struct {
	userID        string
	isDemo        bool
	emailVerified bool
	timezone      string
	locale        string
	isAdmin       bool
}

func authInfoFromContext(ctx context.Context) authInfo {
	info, _ := ctx.Value(authContextKey).(authInfo)
	return info
}

// userIDFromContext is the account requireAuth resolved for this request.
func userIDFromContext(ctx context.Context) string {
	return authInfoFromContext(ctx).userID
}

// timezoneFromContext reads the authenticated user's stored IANA timezone name — the raw
// string a day-bucketing query passes as its own `AT TIME ZONE $N` parameter.
func timezoneFromContext(ctx context.Context) string {
	return authInfoFromContext(ctx).timezone
}

// locationFromContext resolves timezoneFromContext to a *time.Location, for the Go-side date
// math (time.ParseInLocation, time.Now().In(loc)) day-bucketing queries need alongside their
// own SQL-side AT TIME ZONE parameter. Falls back to UTC on a load failure — defensive only,
// since every stored value was already validated with zoneinfo.Load before being written
// (handleSignup, handleUpdateSettings), so this should never actually fail in practice.
func locationFromContext(ctx context.Context) *time.Location {
	return zoneinfo.LoadOr(timezoneFromContext(ctx), time.UTC)
}

// requireAuth wraps a handler that needs a signed-in account, passing the resolved authInfo in
// the request context. The only one of the three auth middlewares that never refuses on
// isDemo or emailVerified: handleResendVerification and handleChangeEmail use it directly, to
// help an account that hasn't verified yet.
func (s *Server) requireAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		info, was, found, err := s.lookupSession(r)
		if err == nil && !found {
			writeAPIError(w, "authentication required", http.StatusUnauthorized)
			return
		}
		if err != nil {
			if clientGone(w, r) {
				return
			}
			// Not a 401: the Android app signs out on one, over what is only a failed lookup.
			s.log.Error("session lookup failed", "err", err)
			writeAPIError(w, "session lookup failed", http.StatusServiceUnavailable)
			return
		}
		if !info.isDemo {
			c, build := requestClient(r.UserAgent(), inApp(r))
			if query, args := seenDue(was, c, build, time.Now()).update(); query != "" {
				if _, err := s.pool.Exec(r.Context(), query, append([]any{info.userID}, args...)...); err != nil {
					s.log.Error("last seen update failed", "err", err)
				}
			}
		}
		next(w, r.WithContext(context.WithValue(r.Context(), authContextKey, info)))
	}
}

// lastSeenDue reports whether a request at now should write users.last_seen_at, given its
// current value (nil when never written): when it isn't yet written on now's UTC day. It counts
// active accounts per day (IMPLEMENTATION.md §4.32), which needs the day, not the request, so an
// account costs one write a day rather than one per request. A day, not 24 hours: someone who
// comes back daily a little earlier each time would otherwise go a day with no write.
func lastSeenDue(lastSeen *time.Time, now time.Time) bool {
	if lastSeen == nil {
		return true
	}
	y1, m1, d1 := lastSeen.UTC().Date()
	y2, m2, d2 := now.UTC().Date()
	return y1 != y2 || m1 != m2 || d1 != d2
}

// requireVerified wraps requireAuth with the email-verification gate (docs/SPEC.md FR-1.8): a real
// (non-demo) account whose email isn't yet confirmed gets a distinguishable 403 instead of
// reaching the handler, so the frontend can render the "verify your email" screen rather than
// a generic error. Demo accounts always pass: the shared demo has no email to verify
// (handleDemoStart). Every signed-in route uses it, except the two that exist to help an
// unverified account (resend-verification, change-email).
func (s *Server) requireVerified(next http.HandlerFunc) http.HandlerFunc {
	return s.requireAuth(func(w http.ResponseWriter, r *http.Request) {
		info := authInfoFromContext(r.Context())
		if !info.isDemo && !info.emailVerified {
			httpErrorT(w, r, http.StatusForbidden, "error.email_not_verified")
			return
		}
		next(w, r)
	})
}

// requireNotDemo layers on top of requireVerified for the write endpoints a demo account must
// never reach (docs/SPEC.md FR-2.1). A real, verified account passes through unchanged; a demo
// account gets a distinguishable 403 a frontend can turn into "create an account to save your
// own data" rather than a generic error.
func (s *Server) requireNotDemo(next http.HandlerFunc) http.HandlerFunc {
	return s.requireVerified(func(w http.ResponseWriter, r *http.Request) {
		if authInfoFromContext(r.Context()).isDemo {
			httpErrorT(w, r, http.StatusForbidden, "error.demo_read_only")
			return
		}
		next(w, r)
	})
}

func isUniqueViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505"
}
