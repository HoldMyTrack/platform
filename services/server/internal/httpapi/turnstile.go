package httpapi

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"time"
)

// turnstile is Cloudflare Turnstile on the /signup page (SPEC.md FR-1.1): the page shows the
// widget, and the form's token is checked with Cloudflare before an account is made. An empty
// site key turns it off, as in development and tests.
type turnstile struct {
	siteKey   string
	secret    string
	verifyURL string
	client    *http.Client
}

const turnstileVerifyURL = "https://challenges.cloudflare.com/turnstile/v0/siteverify"

// turnstileScriptOrigin is where the widget's script loads from; the /signup page's CSP allows it.
const turnstileScriptOrigin = "https://challenges.cloudflare.com"

// turnstileTokenField is the hidden field the widget adds to its form.
const turnstileTokenField = "cf-turnstile-response"

func newTurnstile(siteKey, secret string) turnstile {
	return turnstile{siteKey: siteKey, secret: secret, verifyURL: turnstileVerifyURL, client: &http.Client{Timeout: 10 * time.Second}}
}

func (t turnstile) enabled() bool { return t.siteKey != "" }

// SetTurnstile turns the /signup page's Turnstile check on; an empty siteKey leaves it off.
func (s *Server) SetTurnstile(siteKey, secret string) {
	s.turnstile = newTurnstile(siteKey, secret)
}

// turnstileVerdict is the part of siteverify's answer the check reads.
type turnstileVerdict struct {
	Success    bool     `json:"success"`
	ErrorCodes []string `json:"error-codes"`
}

// turnstileServerCodes are siteverify's error codes no visitor can fix: a refused secret, a
// malformed request, or Cloudflare's own failure.
var turnstileServerCodes = []string{"missing-input-secret", "invalid-input-secret", "bad-request", "internal-error"}

// maxSiteverifyBytes bounds siteverify's answer, a few hundred bytes of JSON.
const maxSiteverifyBytes = 64 << 10

// verify asks Cloudflare whether token passed the challenge for this visitor. A missing token
// fails without a request. An error means no visitor could pass: Cloudflare couldn't answer,
// or answered with one of turnstileServerCodes. The caller refuses the signup either way, so the check
// can't be skipped by making it fail.
func (t turnstile) verify(ctx context.Context, token, remoteIP string) (turnstileVerdict, error) {
	if token == "" {
		return turnstileVerdict{}, nil
	}
	form := url.Values{"secret": {t.secret}, "response": {token}}
	if remoteIP != "" {
		form.Set("remoteip", remoteIP)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, t.verifyURL, strings.NewReader(form.Encode()))
	if err != nil {
		return turnstileVerdict{}, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := t.client.Do(req)
	if err != nil {
		return turnstileVerdict{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return turnstileVerdict{}, fmt.Errorf("turnstile siteverify: status %d", resp.StatusCode)
	}
	var v turnstileVerdict
	if err := json.NewDecoder(io.LimitReader(resp.Body, maxSiteverifyBytes)).Decode(&v); err != nil {
		return turnstileVerdict{}, fmt.Errorf("turnstile siteverify: %w", err)
	}
	if !v.Success && slices.ContainsFunc(v.ErrorCodes, func(c string) bool { return slices.Contains(turnstileServerCodes, c) }) {
		return turnstileVerdict{}, fmt.Errorf("turnstile siteverify: %v", v.ErrorCodes)
	}
	return v, nil
}

// checkTurnstile refuses a /signup form whose token Cloudflare doesn't accept, when Turnstile
// is on: as the visitor's to fix, or, when no visitor could pass, as one to try later.
func (s *Server) checkTurnstile(r *http.Request) error {
	if !s.turnstile.enabled() {
		return nil
	}
	v, err := s.turnstile.verify(r.Context(), r.PostFormValue(turnstileTokenField), clientIP(r))
	if err != nil {
		s.log.Error("turnstile verify failed", "err", err)
		return accountFailure(http.StatusServiceUnavailable, "error.turnstile_unavailable")
	}
	if !v.Success {
		s.log.Debug("turnstile refused a signup", "codes", v.ErrorCodes)
		return accountFailure(http.StatusBadRequest, "error.turnstile_failed")
	}
	return nil
}
