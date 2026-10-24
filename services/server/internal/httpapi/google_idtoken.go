package httpapi

import (
	"context"
	"errors"
	"time"
)

// Verifying a Google id_token a native client hands over — Sign in with Google on Android
// (docs/SPEC.md FR-1.9, docs/IMPLEMENTATION.md §4.9). The web flow's id_token comes
// straight from Google's token endpoint over TLS, so parseGoogleIDToken's claim checks are all
// it needs. One posted by an app could have been written by anyone, so its RS256 signature is
// checked against Google's published keys first (jwks.go) — still with the standard library
// alone, no JWT library, as the rest of the Google flow.

const googleCertsURL = "https://www.googleapis.com/oauth2/v3/certs"

// verifyGoogleIDToken checks an id_token's RS256 signature against Google's keys, then its
// claims exactly as the web flow does (parseGoogleIDToken). The audience is the web client ID:
// Android's Credential Manager is asked for a token for that client (its serverClientId), which
// is what lets this server accept it.
func (s *Server) verifyGoogleIDToken(ctx context.Context, idToken string, now time.Time) (googleClaims, error) {
	if _, err := verifyRS256(ctx, s.google.keys, idToken, now); err != nil {
		return googleClaims{}, errors.New("id_token: " + err.Error())
	}
	return parseGoogleIDToken(idToken, s.google.ClientID, now)
}
