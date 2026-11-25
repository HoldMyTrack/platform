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
	// Used is every type the account's tracks use, the Type picker's list (docs/SPEC.md FR-5.5).
	Used  []typeCount               `json:"used"`
	Types map[string]tracktype.Info `json:"types"`
}

// handleTrackTypes serves `GET /v2/track-types` (docs/SPEC.md FR-5.1, FR-5.5): the account's
// types with how many tracks use each, whatever a client's area or filters, and what a client
// shows for those, the catalog's and any others it names, such as a phone's unsent recordings'.
func (s *Server) handleTrackTypes(w http.ResponseWriter, r *http.Request) {
	var named []string
	if raw := r.URL.Query().Get("types"); raw != "" {
		named = strings.Split(raw, ",")
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
	}
	var used []typeCount
	if err := s.pool.QueryRow(r.Context(), `SELECT `+accountTypeCounts, userIDFromContext(r.Context())).Scan(&used); err != nil {
		if clientGone(w, r) {
			return
		}
		s.log.Error("track types query failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	types := append([]string(nil), tracktype.Catalog...)
	for _, c := range used {
		types = append(types, c.Type)
	}
	types = append(types, named...)
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, trackTypesResponse{Used: used, Types: tracktype.Describe(types, requestLang(r))})
}
