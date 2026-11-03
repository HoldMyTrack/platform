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
// from the catalog and a link back to /guides, and the sitemap lists it.
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
			`<a href="/guides">`,
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

// /guides, in each language, links every guide, and the Info menu links /guides.
func TestGuidesIndex(t *testing.T) {
	s := newPagesTestServer(t)
	for _, lang := range []string{"en", "ru"} {
		req := httptest.NewRequest(http.MethodGet, "/guides", nil)
		req.Header.Set("Accept-Language", lang)
		rec := httptest.NewRecorder()
		s.ServeHTTP(rec, req)
		body := rec.Body.String()
		if rec.Code != http.StatusOK {
			t.Fatalf("%s: status %d", lang, rec.Code)
		}
		for _, g := range web.Guides {
			if !strings.Contains(body, `<a href="`+g.Href+`">`) {
				t.Errorf("%s: /guides doesn't link %s", lang, g.Href)
			}
		}
		if strings.Contains(body, "meta.guides") {
			t.Errorf("%s: untranslated meta key", lang)
		}
	}
	found := false
	for _, l := range web.InfoLinks {
		found = found || l.Href == "/guides"
	}
	if !found {
		t.Error("InfoLinks doesn't link /guides")
	}
}
