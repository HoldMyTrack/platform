package imagery

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/HoldMyTrack/platform/services/server/internal/db"
)

// A Watch stores what it decides: paused at the quota, paused after two failed probes, offered
// again once both are fine, and left as it was when the usage can't be read. Runs on
// TEST_DATABASE_URL (skipped without one; docs/DEVELOPMENT.md), removing its row at the end.
func TestWatch(t *testing.T) {
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	pool, err := db.Open(ctx, url)
	if err != nil {
		t.Fatalf("open test database: %v", err)
	}
	t.Cleanup(pool.Close)
	if err := db.Migrate(ctx, pool); err != nil {
		t.Fatalf("migrate test database: %v", err)
	}
	clean := func() { pool.Exec(context.Background(), `DELETE FROM imagery_status`) }
	clean()
	t.Cleanup(clean)

	if s, ok, err := Load(ctx, pool); err != nil || ok || !s.Available {
		t.Fatalf("no row yet: %+v %v %v, want offered", s, ok, err)
	}

	var used atomic.Int64
	var usageDown, tileDown atomic.Bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/usage"):
			if usageDown.Load() {
				w.WriteHeader(http.StatusBadGateway)
				return
			}
			io.WriteString(w, `{"datasets":[{"data":[{"date":"2026-11-04","value":`+strconv.FormatInt(used.Load(), 10)+`}]}]}`)
		default:
			if tileDown.Load() {
				w.WriteHeader(http.StatusForbidden)
			}
		}
	}))
	defer srv.Close()

	w := NewWatch(Config{Tiles: srv.URL + "/t/{z}/{x}/{y}.jpg", Referer: "https://example.test/", Token: "tok", Limit: 100000}, pool, slog.New(slog.NewTextHandler(io.Discard, nil)))
	w.client = srv.Client()
	w.usageURL = srv.URL + "/usage"
	now := time.Date(2026, 11, 4, 12, 0, 0, 0, time.UTC)
	check := func(want bool, reason string) {
		t.Helper()
		w.Check(ctx, now)
		s, ok, err := Load(ctx, pool)
		if err != nil || !ok || s.Available != want || s.Reason != reason {
			t.Fatalf("at %s: %+v %v %v, want available=%v %q", now.Format("15:04"), s, ok, err, want, reason)
		}
		now = now.Add(CheckInterval)
	}

	used.Store(1366)
	check(true, "")
	used.Store(95000)
	check(false, ReasonQuota)
	used.Store(2000) // a new billing period
	check(true, "")

	tileDown.Store(true)
	check(true, "") // no probe due yet: the last one was 30 minutes ago
	check(true, "") // one failure
	check(true, "") // still one: no probe due
	check(false, ReasonProbe)
	tileDown.Store(false)
	check(false, ReasonProbe) // no probe due yet
	check(true, "")

	used.Store(99000)
	check(false, ReasonQuota)
	usageDown.Store(true)
	check(false, ReasonQuota) // unread usage keeps the pause
}
