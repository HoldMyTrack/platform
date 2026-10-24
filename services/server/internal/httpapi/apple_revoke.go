package httpapi

import (
	"context"
	"net/url"
	"time"
)

// appleLink is an Apple identity's refresh token and the client it was issued to, which
// revoking it needs (docs/SPEC.md FR-1.11, FR-1.14).
type appleLink struct {
	refreshToken, clientID string
}

// appleRevokeTimeout bounds the revocations an account deletion waits for.
const appleRevokeTimeout = 10 * time.Second

// revokeAppleLinks revokes each link's refresh token, as Apple requires when an account is
// deleted. The account is already gone by then, so a failure is only logged: the link it
// revoked no longer leads anywhere here.
func (s *Server) revokeAppleLinks(ctx context.Context, links []appleLink) {
	if len(links) == 0 {
		return
	}
	if !s.apple.enabled() {
		s.log.Warn("apple token not revoked: sign in with apple is not configured", "links", len(links))
		return
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), appleRevokeTimeout)
	defer cancel()
	for _, l := range links {
		secret, err := appleClientSecret(s.apple.AppleOAuthConfig, l.clientID, time.Now())
		if err == nil {
			_, err = s.applePost(ctx, s.apple.revokeURL, url.Values{
				"client_id":       {l.clientID},
				"client_secret":   {secret},
				"token":           {l.refreshToken},
				"token_type_hint": {"refresh_token"},
			})
		}
		if err != nil {
			s.log.Error("apple token revocation failed", "client_id", l.clientID, "err", err)
		}
	}
}
