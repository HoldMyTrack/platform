package httpapi

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/HoldMyTrack/platform/services/server/internal/mapstyle"
)

// TestMapStyleLanguage: ?lang= picks the labels' language on its primary subtag, and anything
// unsupported, or none, is English.
func TestMapStyleLanguage(t *testing.T) {
	s := newPagesTestServer(t)
	for _, tc := range []struct{ query, want string }{
		{"", "en"},
		{"?lang=ru", "ru"},
		{"?lang=ru-RU", "ru"},
		{"?lang=RU", "ru"},
		{"?lang=de", "en"},
	} {
		rec := serveChecked(t, s.ServeHTTP, httptest.NewRequest(http.MethodGet, "/v1/map/style/light"+tc.query, nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("%q: status %d", tc.query, rec.Code)
		}
		if !strings.Contains(rec.Body.String(), `"name:`+tc.want+`"`) {
			t.Errorf("%q: labels aren't name:%s", tc.query, tc.want)
		}
		// A Russian document falls back to name:en too, so English is told apart by this.
		if tc.want == "en" && strings.Contains(rec.Body.String(), `"name:ru"`) {
			t.Errorf("%q: English document reads name:ru", tc.query)
		}
	}
}

// TestEveryMapStyleMatchesContract serves every flavor in every language, with imagery and
// without, through the contract check: each is its own embedded file, and the clients read the
// same HoldMyTrack keys from all of them.
func TestEveryMapStyleMatchesContract(t *testing.T) {
	imagery := mapstyle.Satellite{Tiles: "https://imagery.example/{z}/{x}/{y}.jpg?key=k", TileSize: 512, MaxZoom: 20, Attribution: "Imagery"}
	for _, sat := range []mapstyle.Satellite{{}, imagery} {
		s := newPagesTestServer(t)
		s.satellite = sat
		for _, flavor := range mapstyle.Flavors() {
			for _, lang := range mapstyle.Languages() {
				rec := serveChecked(t, s.ServeHTTP, httptest.NewRequest(http.MethodGet, "/v1/map/style/"+flavor+"?lang="+lang, nil))
				if rec.Code != http.StatusOK {
					t.Fatalf("%s/%s: status %d", flavor, lang, rec.Code)
				}
				if got, want := strings.Contains(rec.Body.String(), `"holdmytrack:satellite-dims"`), sat.Tiles != ""; got != want {
					t.Errorf("%s/%s: satellite metadata %v, want %v", flavor, lang, got, want)
				}
			}
		}
	}
}
