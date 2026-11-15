package httpapi

import (
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
)

// A session lookup that fails, such as a database restart, answers 503: a 401 would tell the
// Android app its session is dead, and it would sign out.
func TestFailedSessionLookupIsNotUnauthorized(t *testing.T) {
	pool, err := pgxpool.New(context.Background(), "postgres://nobody@127.0.0.1:1/none?connect_timeout=1")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	s := &Server{pool: pool, log: slog.New(slog.DiscardHandler)}
	for name, h := range map[string]http.HandlerFunc{
		"requireAuth": s.requireAuth(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) }),
		"me":          s.handleMe,
	} {
		req := httptest.NewRequest(http.MethodGet, "/v1/auth/me", nil)
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
