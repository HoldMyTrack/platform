package httpapi

// Covers docs/SPEC.md FR-5.13 (the Library page's shell; its island is apps/web's).

import (
	"net/http"
	"strings"
	"testing"
)

func TestLibraryPage(t *testing.T) {
	d := newDBTest(t)
	me := d.newAccount(false)
	rec := d.do(me, "GET", "/library", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /library: %d", rec.Code)
	}
	body := rec.Body.String()
	for _, want := range []string{`id="library-root"`, `<noscript><h1 class="profile__title">Library</h1>`, `/assets/library.js?v=`, `/assets/library.css?v=`, `href="/library" aria-current="page"`} {
		if !strings.Contains(body, want) {
			t.Errorf("page is missing %q", want)
		}
	}
	if rec := d.do(account{}, "GET", "/library", nil); rec.Code != http.StatusSeeOther || rec.Header().Get("Location") != "/signin" {
		t.Errorf("signed out: %d %s, want a redirect to sign in", rec.Code, rec.Header().Get("Location"))
	}
}
