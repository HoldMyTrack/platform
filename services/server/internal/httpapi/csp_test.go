package httpapi

import (
	"slices"
	"strings"
	"testing"
)

// directive is the named directive of csp, or "" when it has none.
func directive(csp, name string) string {
	for _, d := range strings.Split(csp, "; ") {
		if d == name || strings.HasPrefix(d, name+" ") {
			return d
		}
	}
	return ""
}

func TestContentSecurityPolicyDefaultsToThisOrigin(t *testing.T) {
	csp := contentSecurityPolicy(cspParts{})
	for _, want := range []string{
		"default-src 'self'", "script-src 'self'", "style-src 'self' 'unsafe-inline'", "img-src 'self' data: blob:",
		"connect-src 'self'", "font-src 'self'", "worker-src 'self' blob:", "frame-src 'none'", "form-action 'self'",
		"object-src 'none'", "base-uri 'self'", "frame-ancestors 'none'",
	} {
		name, _, _ := strings.Cut(want, " ")
		if got := directive(csp, name); got != want {
			t.Errorf("%s: %q, want %q", name, got, want)
		}
	}
}

// The map draws and fetches from its basemap and imagery hosts; a widget's host runs its script
// in its own frame; nothing else widens.
func TestContentSecurityPolicyAllowsWhatThePageUses(t *testing.T) {
	csp := contentSecurityPolicy(cspParts{assets: []string{"https://cdn.example", "https://api.maptiler.com"}, widgets: []string{turnstileScriptOrigin}})
	for name, want := range map[string]string{
		"img-src":     "img-src 'self' data: blob: https://cdn.example https://api.maptiler.com",
		"connect-src": "connect-src 'self' https://cdn.example https://api.maptiler.com",
		"script-src":  "script-src 'self' " + turnstileScriptOrigin,
		"frame-src":   "frame-src " + turnstileScriptOrigin,
		"form-action": "form-action 'self'",
	} {
		if got := directive(csp, name); got != want {
			t.Errorf("%s: %q, want %q", name, got, want)
		}
	}
}

// Local development's dev server calls the API on another localhost port and keeps a websocket
// open; a deployment allows neither.
func TestContentSecurityPolicyInLocalDevelopment(t *testing.T) {
	csp := contentSecurityPolicy(cspParts{local: true})
	if got := directive(csp, "connect-src"); !strings.Contains(got, "http://localhost:*") || !strings.Contains(got, "ws://localhost:*") {
		t.Errorf("local connect-src %q", got)
	}
	if strings.Contains(contentSecurityPolicy(cspParts{}), "localhost") {
		t.Error("a deployment's CSP names localhost")
	}
}

func TestAssetOrigins(t *testing.T) {
	got := assetOrigins("https://holdmytrack.example", "https://tiles.example/basemap", "https://api.maptiler.com/tiles/satellite-v2/{z}/{x}/{y}.jpg?key=k")
	if want := []string{"https://tiles.example", "https://api.maptiler.com"}; !slices.Equal(got, want) {
		t.Errorf("assetOrigins = %v, want %v", got, want)
	}
	// A same-origin basemap and no imagery add nothing.
	if got := assetOrigins("https://holdmytrack.example", "https://holdmytrack.example", ""); len(got) != 0 {
		t.Errorf("same origin: %v, want none", got)
	}
	if got := assetOrigins("https://holdmytrack.example", "", ""); len(got) != 0 {
		t.Errorf("unset: %v, want none", got)
	}
}
