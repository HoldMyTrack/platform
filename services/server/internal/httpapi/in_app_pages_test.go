package httpapi

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// The pages a native app shows in its WebView (SPEC.md FR-10.8) carry appCookieName on every
// request, and render without the site's header, footer and Back to map.

// getPage asks for path as session (signed out when empty), from app's WebView ("android" or
// "ios", the cookie's value) or, when app is empty, a browser.
func getPage(s *Server, path, session, app string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodGet, path, nil)
	if session != "" {
		req.Header.Set("Authorization", bearerPrefix+session)
	}
	if app != "" {
		req.AddCookie(&http.Cookie{Name: appCookieName, Value: app})
	}
	rec := httptest.NewRecorder()
	s.ServeHTTP(rec, req)
	return rec
}

const (
	siteHeader = `class="page-header"`
	siteFooter = `class="page-footer"`
	backToMap  = `class="settings__back"`
)

// A signed-out page is cached per language and app; one app's copy must not be handed to a
// browser or to the other app, whichever is asked for first.
func TestInAppPublicPageIsCachedApart(t *testing.T) {
	s := newPagesTestServer(t)
	for i, app := range []string{"android", "", "ios", "android", "ios", ""} {
		rec := getPage(s, "/about", "", app)
		if rec.Code != http.StatusOK {
			t.Fatalf("request %d: status %d", i, rec.Code)
		}
		body := rec.Body.String()
		inApp := app != ""
		for _, chrome := range []string{siteHeader, siteFooter} {
			if strings.Contains(body, chrome) == inApp {
				t.Errorf("request %d (app %q): %s present = %v", i, app, chrome, !inApp)
			}
		}
		if !strings.Contains(body, `id="funding"`) {
			t.Errorf("request %d (app %q): About's content is missing", i, app)
		}
		// An app is signed in already: no demo button.
		if strings.Contains(body, `href="/signin"`) == inApp {
			t.Errorf("request %d (app %q): demo button present = %v", i, app, !inApp)
		}
		// The iOS app's copy names its own platform, and the others Android's.
		ios := app == "ios"
		if strings.Contains(body, "pick them in the iPhone app") != ios || strings.Contains(body, "through Health Connect") == ios {
			t.Errorf("request %d (app %q): names the wrong platform", i, app)
		}
	}
}

func TestAppPlatform(t *testing.T) {
	for value, want := range map[string]string{"ios": "ios", "android": "android", "1": "android", "": ""} {
		req := httptest.NewRequest(http.MethodGet, "/about", nil)
		if value != "" {
			req.AddCookie(&http.Cookie{Name: appCookieName, Value: value})
		}
		if got := appPlatform(req); got != want {
			t.Errorf("cookie %q: got %q, want %q", value, got, want)
		}
	}
}

func TestInAppAccountPages(t *testing.T) {
	d := newDBTest(t)
	me := d.newAccount(false)
	for _, path := range []string{"/settings", "/profile", "/sync"} {
		web := getPage(d.srv, path, me.session, "").Body.String()
		app := getPage(d.srv, path, me.session, "android").Body.String()
		for _, chrome := range []string{siteHeader, siteFooter, backToMap} {
			if !strings.Contains(web, chrome) {
				t.Errorf("%s in a browser: %s missing", path, chrome)
			}
			if strings.Contains(app, chrome) {
				t.Errorf("%s in-app: %s present", path, chrome)
			}
		}
	}

	// Settings in an app is the account's fields and its limits only: the app has its own
	// Theme, Download your data and Delete account.
	web := getPage(d.srv, "/settings", me.session, "").Body.String()
	app := getPage(d.srv, "/settings", me.session, "android").Body.String()
	for _, page := range []string{web, app} {
		if !strings.Contains(page, `id="account-limits"`) || !strings.Contains(page, "0 of 50,000 activities") {
			t.Error("/settings: the account's limits missing")
		}
	}
	for _, section := range []string{`class="settings__title"`, "data-theme-control", `id="download-data"`, `id="delete-account"`} {
		if !strings.Contains(web, section) {
			t.Errorf("/settings in a browser: %s missing", section)
		}
		if strings.Contains(app, section) {
			t.Errorf("/settings in-app: %s present", section)
		}
	}
	// Sync's heading is the app screen's title, and its text names no Upload menu.
	syncWeb := getPage(d.srv, "/sync", me.session, "").Body.String()
	syncApp := getPage(d.srv, "/sync", me.session, "android").Body.String()
	if !strings.Contains(syncWeb, `id="sync-history"`) || !strings.Contains(syncWeb, "Upload menu") {
		t.Error("/sync in a browser: heading or Upload menu text missing")
	}
	if strings.Contains(syncApp, `id="sync-history"`) || strings.Contains(syncApp, "Upload menu") {
		t.Error("/sync in-app: heading or Upload menu text present")
	}
	// With nothing imported, the app's page points to the app's Sync tab, not the site's header.
	if !strings.Contains(syncWeb, "Upload files from the header") || strings.Contains(syncApp, "Upload files from the header") || !strings.Contains(syncApp, "Sync tab") {
		t.Error("/sync: the empty list's text doesn't fit where it shows")
	}
	for _, app := range []string{"android", "ios"} {
		for _, path := range []string{"/settings", "/profile", "/sync"} {
			body := getPage(d.srv, path, me.session, app).Body.String()
			if app == "ios" && (strings.Contains(body, "Android") || strings.Contains(body, "Health Connect") || strings.Contains(body, "Google Play")) {
				t.Errorf("%s in the iOS app names Android's platform", path)
			}
		}
	}
	for _, field := range []string{`name="display_name"`, `name="country"`, `name="timezone"`, `action="/settings/avatar"`} {
		if !strings.Contains(app, field) {
			t.Errorf("/settings in-app: %s missing", field)
		}
	}
}
