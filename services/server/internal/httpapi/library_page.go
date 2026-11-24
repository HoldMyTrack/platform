package httpapi

import (
	"net/http"

	"github.com/HoldMyTrack/platform/services/server/internal/i18n"
	"github.com/HoldMyTrack/platform/services/server/internal/web"
)

// libraryShell is what templates/pages/library.html reads from PageData.Page.
type libraryShell struct {
	// ViteDev loads the island from Vite's dev server, as appShell's AppPage.ViteDev does.
	ViteDev bool
}

// GET /library: the Library page (docs/SPEC.md FR-17.1), a server page holding a React island
// (apps/web's library/main.tsx) that lists the tracks from `GET /v2/tracks?page=` and keeps its
// sort, filters and page in the URL. Signed out goes to sign in, and a session with somewhere
// else to be first goes there, as for the map.
func (s *Server) handleLibraryPage(w http.ResponseWriter, r *http.Request) {
	acct, ok := s.pageAccount(w, r)
	if !ok {
		return
	}
	if acct == nil {
		http.Redirect(w, r, "/signin", http.StatusSeeOther)
		return
	}
	if home := acct.home(); home != "/" {
		http.Redirect(w, r, home, http.StatusSeeOther)
		return
	}
	lang := pageLang(acct, r)
	l := i18n.Get(lang)
	s.pages.Render(w, http.StatusOK, "library", web.PageData{
		Title: l.T("meta.library_title"), Path: "/library", NoIndex: true, User: acct.user, Lang: lang, App: appPlatform(r),
		Page: libraryShell{ViteDev: s.pages.Dev() && r.Header.Get(viteDevHeader) == "dev"},
	})
}
