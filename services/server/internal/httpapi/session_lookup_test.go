package httpapi

import (
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
)

// A session lookup that fails, such as a database restart, answers 503: a 401 would tell the
// Android app its session is dead, and it would sign out.
func TestFailedSessionLookupIsNotUnauthorized(t *testing.T) {
	s := &Server{pool: unreachablePool(t), log: slog.New(slog.DiscardHandler)}
	for name, h := range map[string]http.HandlerFunc{
		"requireAuth": s.requireAuth(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) }),
		"me":          s.handleMe,
	} {
		req := httptest.NewRequest(http.MethodGet, "/v2/auth/me", nil)
		req.Header.Set("Authorization", bearerPrefix+"a-session")
		rec := serveChecked(t, h, req)
		if rec.Code != http.StatusServiceUnavailable {
			t.Errorf("%s with the database unreachable: %d, want 503", name, rec.Code)
		}
		// A client that hung up isn't a failed lookup: nothing to answer or log as one.
		gone, cancel := context.WithCancel(context.Background())
		cancel()
		rec = httptest.NewRecorder()
		h(rec, req.WithContext(gone))
		if rec.Code == http.StatusServiceUnavailable {
			t.Errorf("%s for a request its client cancelled: 503, want it left as the client's", name)
		}
	}
}

// A page whose session can't be looked up answers 503 with the unavailable page, and never
// draws the visitor signed out or sends them to sign in; one with no session never looks.
func TestFailedPageSessionLookupIsUnavailable(t *testing.T) {
	s := newPagesTestServer(t)
	s.pool = unreachablePool(t)
	for _, path := range []string{"/", "/settings", "/profile", "/signin", "/about", "/no-such-page"} {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		req.AddCookie(&http.Cookie{Name: sessionCookieName, Value: "a-session"})
		rec := httptest.NewRecorder()
		s.ServeHTTP(rec, req)
		if rec.Code != http.StatusServiceUnavailable || rec.Header().Get("Retry-After") == "" || !strings.Contains(rec.Body.String(), "Temporarily unavailable") {
			t.Errorf("%s with a session: status %d, Retry-After %q; want 503 and the unavailable page", path, rec.Code, rec.Header().Get("Retry-After"))
		}
	}
	rec := httptest.NewRecorder()
	s.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/about", nil))
	if rec.Code != http.StatusOK {
		t.Errorf("/about signed out: status %d, want 200 without a lookup", rec.Code)
	}
}

// unreachablePool is a pool whose database can't be reached, so every query fails rather than
// finding nothing.
func unreachablePool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	pool, err := pgxpool.New(context.Background(), "postgres://nobody@127.0.0.1:1/none?connect_timeout=1")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	return pool
}
