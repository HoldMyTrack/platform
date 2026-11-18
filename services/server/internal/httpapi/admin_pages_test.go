package httpapi

// Covers docs/SPEC.md FR-11 (the admin panel).

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/HoldMyTrack/platform/services/server/internal/i18n"
	"github.com/HoldMyTrack/platform/services/server/internal/web"
)

func TestAdminPagesSignedOutAreNotFound(t *testing.T) {
	s := newPagesTestServer(t)
	for _, path := range []string{"/admin", "/admin/users", "/admin/users/b123028b-354d-4838-bb84-b31213269791"} {
		rec := httptest.NewRecorder()
		s.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
		if rec.Code != http.StatusNotFound || !strings.Contains(rec.Body.String(), "Page not found") {
			t.Errorf("%s: status %d, want the ordinary 404 page", path, rec.Code)
		}
	}
}

func TestAdminPagesRender(t *testing.T) {
	s := newPagesTestServer(t)
	admin := &web.User{Email: "admin@example.com", IsAdmin: true}
	user := adminUserRow{ID: "u-1", Email: "rider@example.com", DisplayName: "Rider", SignedUp: "2026-08-01", Timezone: "Europe/Rome", Verified: true, Tracks: "2", Distance: "12 km", LastSeen: "2026-09-20", Clients: adminClients{Web: true, IOS: true}}

	rec := httptest.NewRecorder()
	s.pages.Render(rec, http.StatusOK, "admin", web.PageData{Title: "Accounts", Path: "/admin/users", NoIndex: true, User: admin, Page: adminUsersView{Users: []adminUserRow{user}, Range: "101–101 of 101", PrevHref: "/admin/users"}})
	body := rec.Body.String()
	for _, want := range []string{`href="/admin/users/u-1"`, "rider@example.com", "Europe/Rome", "2026-09-20", `<span class="admin__badge">web</span><span class="admin__badge">iOS</span>`, `href="/admin">Admin</a>`, `href="/admin">← Statistics</a>`, "101–101 of 101", `<a href="/admin/users">← Newer</a>`} {
		if !strings.Contains(body, want) {
			t.Errorf("admin page: missing %q", want)
		}
	}

	rec = httptest.NewRecorder()
	s.pages.Render(rec, http.StatusOK, "admin-user", web.PageData{Title: "Rider", Path: "/admin/users/u-1", NoIndex: true, User: admin, Page: adminUserView{
		User:     user,
		Range:    "1–2 of 2",
		NextHref: "/admin/users/u-1?page=2",
		Tracks: []adminTrackRow{
			{ID: "a-1", Started: "2026-09-20 08:15", Type: "walk", Countries: "Italy", Regions: "Emilia-Romagna", Edited: true},
			{ID: "a-2", Started: "2026-09-19 18:00", Type: "walk", Hidden: true},
		},
	}})
	body = rec.Body.String()
	for _, want := range []string{`<code class="admin__id">a-1</code>`, "Emilia-Romagna", ">hidden<", ">edited<", "1–2 of 2", `href="/admin/users/u-1?page=2"`} {
		if !strings.Contains(body, want) {
			t.Errorf("admin user page: missing %q", want)
		}
	}
}

func TestAdminMenuItemOnlyForAdmins(t *testing.T) {
	s := newPagesTestServer(t)
	for _, tc := range []struct {
		user *web.User
		want bool
	}{
		{&web.User{Email: "a@example.com", IsAdmin: true}, true},
		{&web.User{Email: "b@example.com"}, false},
	} {
		rec := httptest.NewRecorder()
		s.pages.Render(rec, http.StatusOK, "help", web.PageData{Title: "Help", Path: "/help", User: tc.user})
		if got := strings.Contains(rec.Body.String(), `href="/admin"`); got != tc.want {
			t.Errorf("%s: Admin item shown = %v, want %v", tc.user.Email, got, tc.want)
		}
	}
}

func TestAdminFormatting(t *testing.T) {
	for secs, want := range map[int64]string{0: "0:00", 29: "0:00", 30: "0:01", 2520: "0:42", 43500: "12:05"} {
		if got := adminDuration(secs); got != want {
			t.Errorf("adminDuration(%d) = %q, want %q", secs, got, want)
		}
	}
	if got := adminRange(i18n.Get("en"), 100, 100, 1250); got != "101–200 of 1,250" {
		t.Errorf("adminRange = %q", got)
	}
	if got := adminRange(i18n.Get("ru"), 100, 100, 1250); got != "101–200 из 1\u00a0250" {
		t.Errorf("adminRange ru = %q", got)
	}
	if got := adminUserHref("u", 1); got != "/admin/users/u" {
		t.Errorf("page 1 href = %q", got)
	}
	if got := adminUserHref("u", 3); got != "/admin/users/u?page=3" {
		t.Errorf("page 3 href = %q", got)
	}
}

func TestAdminPages(t *testing.T) {
	for _, tc := range []struct {
		page, total      int
		offset           int
		past, prev, next bool
	}{
		{1, 0, 0, true, false, false},
		{1, 100, 0, false, false, false},
		{1, 101, 0, false, false, true},
		{2, 101, 100, false, true, false},
		{3, 101, 200, true, true, false},
	} {
		offset, past, prev, next := adminPages(tc.page, tc.total, 100)
		if offset != tc.offset || past != tc.past || prev != tc.prev || next != tc.next {
			t.Errorf("adminPages(%d, %d) = %d, past %v, prev %v, next %v; want %d, %v, %v, %v",
				tc.page, tc.total, offset, past, prev, next, tc.offset, tc.past, tc.prev, tc.next)
		}
	}
}

func TestClientsInUse(t *testing.T) {
	day := func(month time.Month, d int) *time.Time {
		t := time.Date(2026, month, d, 0, 0, 0, 0, time.UTC)
		return &t
	}
	for _, tc := range []struct {
		name              string
		web, android, ios *time.Time
		want              adminClients
	}{
		{"never seen", nil, nil, nil, adminClients{}},
		{"web only, long ago", day(1, 5), nil, nil, adminClients{Web: true}},
		{"all three within 30 days", day(11, 1), day(11, 20), day(11, 30), adminClients{Web: true, Android: true, IOS: true}},
		{"moved from iOS to Android", nil, day(12, 15), day(11, 14), adminClients{Android: true}},
		{"30 days apart still counts", nil, day(12, 1), day(11, 1), adminClients{Android: true, IOS: true}},
		{"31 days apart doesn't", nil, day(12, 2), day(11, 1), adminClients{Android: true}},
	} {
		if got := clientsInUse(tc.web, tc.android, tc.ios); got != tc.want {
			t.Errorf("%s: clientsInUse = %+v, want %+v", tc.name, got, tc.want)
		}
	}
}
