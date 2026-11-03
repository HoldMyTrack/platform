package httpapi

import (
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/HoldMyTrack/platform/services/server/internal/web"
)

// Each guide renders signed out as an indexable page of its own, with a title and description
// from the catalog, the footer links it, and the sitemap lists it.
func TestGuidePages(t *testing.T) {
	sitemap, err := os.ReadFile("../../../../apps/web/public/sitemap.xml")
	if err != nil {
		t.Fatal(err)
	}
	s := newPagesTestServer(t)
	for _, g := range web.Guides {
		rec := httptest.NewRecorder()
		s.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, g.Href, nil))
		body := rec.Body.String()
		if rec.Code != http.StatusOK {
			t.Fatalf("%s: status %d", g.Href, rec.Code)
		}
		for _, want := range []string{
			`<link rel="canonical" href="https://app.example` + g.Href + `"`,
			`<meta name="description" content="`,
			"— HoldMyTrack</title>",
			`href="/signup"`,
			`<a href="/fog-of-war">`, // the footer's guides row
		} {
			if !strings.Contains(body, want) {
				t.Errorf("%s: missing %q", g.Href, want)
			}
		}
		for _, leftover := range []string{"meta." + g.MetaKey, "noindex"} {
			if strings.Contains(body, leftover) {
				t.Errorf("%s: has %q", g.Href, leftover)
			}
		}
		if !strings.Contains(string(sitemap), "<loc>https://holdmytrack.com"+g.Href+"</loc>") {
			t.Errorf("sitemap.xml doesn't list %s", g.Href)
		}
	}
}
