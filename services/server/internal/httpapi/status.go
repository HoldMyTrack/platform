package httpapi

import (
	"errors"
	"net/http"

	"github.com/jackc/pgx/v5"

	"github.com/HoldMyTrack/platform/services/server/internal/i18n"
)

type statusResponse struct {
	Status string `json:"status"` // "processing" | "done" | "failed" | "unknown"
	Error  string `json:"error,omitempty"`
}

// handleUploadStatus serves `GET /v1/uploads/{external_id}`: what an upload's "enqueued" answer
// resolved to, from the caller's own latest ingest job for that id. The job, not the activities
// table, since a failed job leaves no activity, so "failed" and "never uploaded" would read alike.
// Only the caller's: an upload's id is its file's SHA-256, which would otherwise tell anyone
// holding a file whether another account uploaded it.
func (s *Server) handleUploadStatus(w http.ResponseWriter, r *http.Request) {
	externalID := r.PathValue("external_id")
	if externalID == "" {
		writeAPIError(w, "missing external_id", http.StatusBadRequest)
		return
	}

	var state string
	var lastError, errorCode *string
	err := s.pool.QueryRow(r.Context(),
		`SELECT state, last_error, error_code FROM jobs
		 WHERE user_id = $2 AND kind = 'ingest' AND payload->>'external_id' = $1
		 ORDER BY id DESC LIMIT 1`,
		externalID, userIDFromContext(r.Context()),
	).Scan(&state, &lastError, &errorCode)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			writeJSON(w, http.StatusOK, statusResponse{Status: "unknown"})
			return
		}
		s.log.Error("status query failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}

	resp := statusResponse{}
	switch state {
	case "pending":
		resp.Status = "processing"
	case "done":
		resp.Status = "done"
	case "failed":
		resp.Status = "failed"
		resp.Error = jobErrorMessage(i18n.Get(requestLang(r)), errorCode, lastError)
	default:
		resp.Status = state // forward-compatible with any future jobs.state value
	}
	writeJSON(w, http.StatusOK, resp)
}
