package config

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"strings"
	"testing"
)

func TestRateLimitsOff(t *testing.T) {
	t.Setenv("S3_ENDPOINT", "http://rustfs:9000")
	cases := []struct {
		value, baseURL string
		off, fails     bool
	}{
		{"", "https://holdmytrack.app", false, false},
		{"on", "https://holdmytrack.app", false, false},
		{"off", "http://localhost:5173", true, false},
		{"off", "http://127.0.0.1:8080", true, false},
		{"off", "http://[::1]:8080", true, false},
		{"off", "https://holdmytrack.app", false, true},
		{"off", "http://localhost.holdmytrack.app", false, true},
		{"no", "http://localhost:5173", false, true},
	}
	for _, c := range cases {
		t.Setenv("RATE_LIMITS", c.value)
		t.Setenv("APP_BASE_URL", c.baseURL)
		cfg, err := Load()
		if (err != nil) != c.fails {
			t.Errorf("RATE_LIMITS=%q at %s: error %v, want failure %v", c.value, c.baseURL, err, c.fails)
			continue
		}
		if err == nil && cfg.RateLimitsOff != c.off {
			t.Errorf("RATE_LIMITS=%q at %s: off %v, want %v", c.value, c.baseURL, cfg.RateLimitsOff, c.off)
		}
	}
}

func TestApplePrivateKey(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	p8 := string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))
	for name, v := range map[string]string{
		"the .p8 file":     p8,
		"newlines as \\n":  strings.ReplaceAll(p8, "\n", `\n`),
		"the base64 alone": base64.StdEncoding.EncodeToString(der),
	} {
		got, err := applePrivateKey(v)
		if err != nil || !got.Equal(key) {
			t.Errorf("%s: %v", name, err)
		}
	}
	for name, v := range map[string]string{"empty": "", "garbage": "not a key"} {
		if _, err := applePrivateKey(v); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestAppleNeedsItsKey(t *testing.T) {
	t.Setenv("S3_ENDPOINT", "http://rustfs:9000")
	t.Setenv("APPLE_SERVICES_ID", "com.holdmytrack.web")
	t.Setenv("APPLE_TEAM_ID", "TEAM123456")
	t.Setenv("APPLE_KEY_ID", "KEY1234567")
	if _, err := Load(); err == nil {
		t.Fatal("loaded without APPLE_PRIVATE_KEY")
	}
	t.Setenv("APPLE_SERVICES_ID", "")
	t.Setenv("APPLE_BUNDLE_ID", "dev.holdmytrack.ios")
	if _, err := Load(); err == nil {
		t.Fatal("loaded a bundle id without a services id")
	}
}
