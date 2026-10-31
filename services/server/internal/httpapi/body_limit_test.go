package httpapi

import (
	"bytes"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
)

// The body cap follows the route, never the client's Content-Type: a multipart-labelled body on
// a JSON route is capped, and an upload route is left to its own limit.
func TestBodyLimitFollowsTheRouteNotTheContentType(t *testing.T) {
	s := &Server{log: slog.New(slog.DiscardHandler), mux: http.NewServeMux()}
	read := map[string]int64{}
	record := func(w http.ResponseWriter, r *http.Request) {
		n, err := io.Copy(io.Discard, r.Body)
		if err != nil {
			n = -1
		}
		read[r.Method+" "+r.URL.Path] = n
	}
	for _, p := range []string{"POST /v1/auth/login", "POST /v1/activities/upload", "POST /signin", "POST /settings/avatar"} {
		s.mux.HandleFunc(p, record)
	}

	big := int64(maxJSONBodyBytes + 1<<10)
	for _, tc := range []struct {
		path string
		want int64
	}{
		{"/v1/auth/login", -1},
		{"/signin", -1},
		{"/v1/activities/upload", big},
		{"/settings/avatar", big},
	} {
		req := httptest.NewRequest("POST", tc.path, bytes.NewReader(make([]byte, big)))
		req.Header.Set("Content-Type", "multipart/form-data; boundary=x")
		s.ServeHTTP(httptest.NewRecorder(), req)
		if got := read["POST "+tc.path]; got != tc.want {
			t.Errorf("POST %s read %d bytes, want %d (-1 = refused past the cap)", tc.path, got, tc.want)
		}
	}
}
