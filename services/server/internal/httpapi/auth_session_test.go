package httpapi

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// The cookie wins over a bearer token, and an empty one of either counts as none.
func TestSessionIDFromRequest(t *testing.T) {
	for name, tc := range map[string]struct {
		cookie, authorization string
		want                  string
		ok                    bool
	}{
		"none":             {},
		"cookie":           {cookie: "c", want: "c", ok: true},
		"bearer":           {authorization: "Bearer b", want: "b", ok: true},
		"cookie first":     {cookie: "c", authorization: "Bearer b", want: "c", ok: true},
		"empty cookie":     {cookie: "", authorization: "Bearer b", want: "b", ok: true},
		"empty bearer":     {authorization: "Bearer ", ok: false},
		"another scheme":   {authorization: "Basic YTpi", ok: false},
		"lowercase bearer": {authorization: "bearer b", ok: false},
	} {
		r := httptest.NewRequest(http.MethodGet, "/", nil)
		if tc.cookie != "" {
			r.AddCookie(&http.Cookie{Name: sessionCookieName, Value: tc.cookie})
		}
		if tc.authorization != "" {
			r.Header.Set("Authorization", tc.authorization)
		}
		got, ok := sessionIDFromRequest(r)
		if got != tc.want || ok != tc.ok {
			t.Errorf("%s: got %q %v, want %q %v", name, got, ok, tc.want, tc.ok)
		}
	}
}
