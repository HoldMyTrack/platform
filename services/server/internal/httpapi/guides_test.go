package httpapi

import (
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

// Each guide renders signed out as an indexable page of its own, with a title and description
// from the catalog, and the sitemap lists it so a crawler finds it without the Info menu.
func TestGuidePages(t *testing.T) {
	sitemap, err := os.ReadFile("../../../../apps/web/public/sitemap.xml")
	if err != nil {
		t.Fatal(err)
	}
	s := newPagesTestServer(t)
	for _, g := range guidePages {
		rec := httptest.NewRecorder()
		s.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, g.Path, nil))
		body := rec.Body.String()
		if rec.Code != http.StatusOK {
			t.Fatalf("%s: status %d", g.Path, rec.Code)
		}
		for _, want := range []string{
			`<link rel="canonical" href="https://app.example` + g.Path + `"`,
			`<meta name="description" content="`,
			"— HoldMyTrack</title>",
			`href="/signup"`,
		} {
			if !strings.Contains(body, want) {
				t.Errorf("%s: missing %q", g.Path, want)
			}
		}
		for _, leftover := range []string{"meta." + g.Key, "noindex"} {
			if strings.Contains(body, leftover) {
				t.Errorf("%s: has %q", g.Path, leftover)
			}
		}
		if !strings.Contains(string(sitemap), "<loc>https://holdmytrack.com"+g.Path+"</loc>") {
			t.Errorf("sitemap.xml doesn't list %s", g.Path)
		}
	}
}
