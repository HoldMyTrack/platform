package httpapi

import (
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/HoldMyTrack/platform/services/server/internal/mapstyle"
	"github.com/HoldMyTrack/platform/services/server/internal/web"
)

// The dev servers' origins may call the API only in local development: a deployment answers
// them as any other foreign origin.
func TestDevOriginsOnlyInLocalDevelopment(t *testing.T) {
	for _, tc := range []struct {
		appBaseURL string
		allowed    bool
	}{
		{"http://localhost:5173", true},
		{"https://holdmytrack.example", false},
	} {
		pages, err := web.New(web.Embedded(), false, "test", tc.appBaseURL)
		if err != nil {
			t.Fatal(err)
		}
		s := New(nil, nil, slog.New(slog.DiscardHandler), nil, tc.appBaseURL, "", mapstyle.Satellite{}, "test", false, GoogleOAuthConfig{}, FacebookOAuthConfig{}, AppleOAuthConfig{}, pages)
		req := httptest.NewRequest(http.MethodGet, "/no-such-page", nil)
		req.Header.Set("Origin", "http://localhost:5173")
		rec := httptest.NewRecorder()
		s.ServeHTTP(rec, req)
		got := rec.Header().Get("Access-Control-Allow-Origin") == "http://localhost:5173"
		if got != tc.allowed {
			t.Errorf("APP_BASE_URL %s: dev origin allowed = %v, want %v", tc.appBaseURL, got, tc.allowed)
		}
		// An allowed origin can read a download's file name.
		if exposed := rec.Header().Get("Access-Control-Expose-Headers") == "Content-Disposition"; exposed != tc.allowed {
			t.Errorf("APP_BASE_URL %s: Content-Disposition exposed = %v, want %v", tc.appBaseURL, exposed, tc.allowed)
		}
	}
}
