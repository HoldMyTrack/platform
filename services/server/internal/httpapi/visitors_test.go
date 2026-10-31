package httpapi

// Covers docs/SPEC.md FR-12.4 (unique web visitors).

import (
	"bytes"
	"testing"
)

const firefox = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14.6; rv:131.0) Gecko/20100101 Firefox/131.0"

func TestCountsAsVisitor(t *testing.T) {
	for _, tc := range []struct {
		name   string
		route  string
		status int
		ua     string
		inApp  bool
		want   bool
	}{
		{"home page", "GET /{$}", 200, firefox, false, true},
		{"about", "GET /about", 200, firefox, false, true},
		{"redirected", "GET /settings", 303, firefox, false, false},
		{"admin panel", "GET /admin", 200, firefox, false, false},
		{"form post", "POST /signin", 200, firefox, false, false},
		{"api", "GET /v1/activities", 200, firefox, false, false},
		{"app webview", "GET /help", 200, firefox, true, false},
		{"no user agent", "GET /about", 200, "", false, false},
		{"crawler", "GET /about", 200, "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)", false, false},
		{"link preview", "GET /{$}", 200, "facebookexternalhit/1.1 Preview", false, false},
		{"curl", "GET /{$}", 200, "curl/8.7.1", false, false},
		{"headless chrome", "GET /{$}", 200, "Mozilla/5.0 HeadlessChrome/131.0", false, false},
	} {
		if got := countsAsVisitor(tc.route, tc.status, tc.ua, tc.inApp); got != tc.want {
			t.Errorf("%s: countsAsVisitor = %v, want %v", tc.name, got, tc.want)
		}
	}
}

func TestVisitorHash(t *testing.T) {
	salt := []byte("salt-1")
	a := visitorHash(salt, "203.0.113.7", firefox)
	if a != visitorHash(salt, "203.0.113.7", firefox) {
		t.Error("the same visitor under one salt hashes differently")
	}
	if a == visitorHash([]byte("salt-2"), "203.0.113.7", firefox) {
		t.Error("a new day's salt hashes the visitor the same")
	}
	if a == visitorHash(salt, "203.0.113.8", firefox) || a == visitorHash(salt, "203.0.113.7", firefox+"x") {
		t.Error("another address or browser hashes the same")
	}
	// The separator keeps the address and agent apart: "1.2.3.4" + "5x" isn't "1.2.3.45" + "x".
	if visitorHash(salt, "1.2.3.4", "5x") == visitorHash(salt, "1.2.3.45", "x") {
		t.Error("address and agent run together")
	}
	if bytes.Equal(a[:], make([]byte, 16)) {
		t.Error("empty hash")
	}
}
