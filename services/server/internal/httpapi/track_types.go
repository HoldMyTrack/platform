package httpapi

import (
	"net/http"
	"strings"
	"unicode/utf8"

	"github.com/HoldMyTrack/platform/services/server/internal/tracktype"
)

// maxDescribedTypes bounds `GET /v2/track-types?types=`: a phone's Sync tab names the types of
// what it holds, a few dozen at most.
const maxDescribedTypes = 100

type trackTypesResponse struct {
	Types map[string]tracktype.Info `json:"types"`
}

// handleTrackTypes serves `GET /v2/track-types` (docs/SPEC.md FR-5.1): what a client shows
// for the catalog's types and any others it names — the Type picker's suggestions, and types no
// list response has carried, such as a phone's unsent recordings.
func (s *Server) handleTrackTypes(w http.ResponseWriter, r *http.Request) {
	types := append([]string(nil), tracktype.Catalog...)
	if raw := r.URL.Query().Get("types"); raw != "" {
		named := strings.Split(raw, ",")
		if len(named) > maxDescribedTypes {
			writeAPIError(w, "too many types", http.StatusBadRequest)
			return
		}
		for _, t := range named {
			if t == "" || utf8.RuneCountInString(t) > maxTrackTypeLen {
				writeAPIError(w, "each type must be 1 to 50 characters", http.StatusBadRequest)
				return
			}
		}
		types = append(types, named...)
	}
	writeJSON(w, http.StatusOK, trackTypesResponse{Types: tracktype.Describe(types, requestLang(r))})
}
