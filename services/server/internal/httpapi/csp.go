package httpapi

import (
	"net/url"
	"strings"
)

// cspParts is what a page's Content-Security-Policy allows besides this origin.
type cspParts struct {
	// assets are the origins the map fetches its basemap and imagery from: tiles, fonts, sprites.
	assets []string
	// widgets are the origins a page runs a third party's script and frame from: Turnstile's.
	widgets []string
	// local allows any localhost port, as local development needs: the dev server's page calls
	// the API on another port, and Vite injects styles and keeps a websocket open.
	local bool
}

// contentSecurityPolicy is a page's CSP. Everything defaults to this origin; the map's basemap and
// imagery hosts may be fetched and drawn, a widget's host may run its script in its frame, and
// forms post only here. Styles allow inline: the templates' style attributes and Vite's dev
// styles need it, and an injected style can't run code.
func contentSecurityPolicy(p cspParts) string {
	join := func(base string, more ...[]string) string {
		parts := []string{base}
		for _, m := range more {
			parts = append(parts, m...)
		}
		return strings.Join(parts, " ")
	}
	var local, localSockets []string
	if p.local {
		local = []string{"http://localhost:*", "http://127.0.0.1:*"}
		localSockets = []string{"ws://localhost:*", "ws://127.0.0.1:*"}
	}
	frames := "frame-src 'none'"
	if len(p.widgets) > 0 {
		frames = join("frame-src", p.widgets)
	}
	directives := []string{
		"default-src 'self'",
		join("script-src 'self'", p.widgets),
		"style-src 'self' 'unsafe-inline'",
		join("img-src 'self' data: blob:", p.assets, local),
		join("connect-src 'self'", p.assets, local, localSockets),
		"font-src 'self'",
		"worker-src 'self' blob:",
		frames,
		"form-action 'self'",
		"object-src 'none'",
		"base-uri 'self'",
		"frame-ancestors 'none'",
	}
	return strings.Join(directives, "; ")
}

// originOf is rawURL's scheme and host, or "" for one without both: a tile template's {z}/{x}/{y}
// and query stay out of the policy.
func originOf(rawURL string) string {
	u, err := url.Parse(rawURL)
	if err != nil || u.Scheme == "" || u.Host == "" {
		return ""
	}
	return u.Scheme + "://" + u.Host
}

// assetOrigins are the map's basemap and imagery hosts other than appBaseURL's own.
func assetOrigins(appBaseURL, basemapOrigin, satelliteTiles string) []string {
	self := originOf(appBaseURL)
	var origins []string
	for _, raw := range []string{basemapOrigin, satelliteTiles} {
		if o := originOf(raw); o != "" && o != self {
			origins = append(origins, o)
		}
	}
	return origins
}
