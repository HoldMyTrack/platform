package httpapi

import (
	"net/http"
	"strings"
)

// maxPendingIDs bounds `GET /v1/activities/pending?ids=`: a client asks about the rows its list
// shows Pending and the edits it saved, a handful at a time.
const maxPendingIDs = 200

type pendingResponse struct {
	Pending []string `json:"pending"`
}

// handleActivitiesPending serves `GET /v1/activities/pending?ids=` (§4.2.5): which of the given
// activities are still Pending. A client watching a reprocess asks this every few seconds and
// reads the whole list again only once the answer changes. An id that isn't the account's, or
// no longer exists, is simply not Pending.
func (s *Server) handleActivitiesPending(w http.ResponseWriter, r *http.Request) {
	ids := strings.Split(r.URL.Query().Get("ids"), ",")
	if len(ids) > maxPendingIDs {
		writeAPIError(w, "too many ids", http.StatusBadRequest)
		return
	}
	for i, id := range ids {
		if !uuidPattern.MatchString(id) {
			writeAPIError(w, "ids must be activity ids, comma-separated", http.StatusBadRequest)
			return
		}
		ids[i] = strings.ToLower(id)
	}
	rows, err := s.pool.Query(r.Context(), `
		SELECT id::text FROM activities WHERE user_id = $1 AND edit_pending AND id = ANY($2::uuid[])
	`, userIDFromContext(r.Context()), ids)
	if err != nil {
		s.log.Error("pending check failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	defer rows.Close()
	resp := pendingResponse{Pending: []string{}}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			s.log.Error("pending check scan failed", "err", err)
			writeAPIError(w, "internal error", http.StatusInternalServerError)
			return
		}
		resp.Pending = append(resp.Pending, id)
	}
	if err := rows.Err(); err != nil {
		s.log.Error("pending check read failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, resp)
}
