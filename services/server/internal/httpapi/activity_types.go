package httpapi

import (
	"net/http"
	"strings"

	"github.com/HoldMyTrack/platform/services/server/internal/activitytype"
)

// maxDescribedTypes bounds `GET /v1/activity-types?types=`: a phone's Sync tab names the types of
// what it holds, a few dozen at most.
const maxDescribedTypes = 100

type activityTypesResponse struct {
	Types map[string]activitytype.Info `json:"types"`
}

// handleActivityTypes serves `GET /v1/activity-types` (docs/SPEC.md FR-5.1): what a client shows
// for the catalog's types and any others it names — the Type picker's suggestions, and types no
// list response has carried, such as a phone's unsent recordings.
func (s *Server) handleActivityTypes(w http.ResponseWriter, r *http.Request) {
	types := append([]string(nil), activitytype.Catalog...)
	if raw := r.URL.Query().Get("types"); raw != "" {
		named := strings.Split(raw, ",")
		if len(named) > maxDescribedTypes {
			writeAPIError(w, "too many types", http.StatusBadRequest)
			return
		}
		for _, t := range named {
			if t == "" || len(t) > maxActivityTypeLen {
				writeAPIError(w, "each type must be 1 to 50 characters", http.StatusBadRequest)
				return
			}
		}
		types = append(types, named...)
	}
	writeJSON(w, http.StatusOK, activityTypesResponse{Types: activitytype.Describe(types, requestLang(r))})
}
