package httpapi

import (
	"net/http"
	"time"

	"github.com/HoldMyTrack/platform/services/server/internal/i18n"
	"github.com/HoldMyTrack/platform/services/server/internal/ingest"
)

// activeImport is one row of the header's Upload menu (IMPLEMENTATION.md §4.0): an import
// still being processed — a single uploaded file, or every job one request enqueued together
// (a phone sync's tracks, ingest.Job.Batch), with how many of them have finished. A row leaves
// the list once all of its jobs have.
type activeImport struct {
	Title       string    `json:"title"`
	Source      string    `json:"source"`
	Done        int64     `json:"done"`
	Total       int64     `json:"total"`
	SubmittedAt time.Time `json:"submitted_at"`
}

// importFailure is an import that failed unseen: after the account last opened /sync
// (users.imports_seen_at), and not dismissed (jobs.seen_at). The Upload menu lists it with its
// reason until dismissed (POST /v2/uploads/seen).
type importFailure struct {
	ID         int64     `json:"id"`
	Title      string    `json:"title"`
	Reason     string    `json:"reason"`
	FinishedAt time.Time `json:"finished_at"`
}

type activeImportsResponse struct {
	Imports []activeImport `json:"imports"`
	// How many imports failed unseen; Failures lists the newest maxListedFailures of them.
	UnseenFailures int64           `json:"unseen_failures"`
	Failures       []importFailure `json:"failures"`
}

// maxListedFailures bounds the failures one response lists: an ingest fails only on our side
// (IMPLEMENTATION.md §4.1), so more than a few at once is an outage. The rest come up as the
// listed ones are dismissed.
const maxListedFailures = 20

// activeImportsQuery groups the account's ingest jobs by batch — a job with none is a group of
// its own — and keeps the groups that still have a pending job. The title is the job's file
// name; a phone sync has none worth showing (its source_detail is a platform id), so
// importTitle names it after its source instead.
const activeImportsQuery = `
WITH grouped AS (
  SELECT COALESCE(NULLIF(payload->>'batch', ''), id::text) AS grp, payload, state, created_at
  FROM jobs
  WHERE kind = 'ingest' AND user_id = $1
)
SELECT MIN(payload->>'source'),
       COALESCE(MIN(payload->>'source_detail'), ''),
       COUNT(*) FILTER (WHERE state <> 'pending'),
       COUNT(*),
       MIN(created_at)
FROM grouped
WHERE grp IN (SELECT grp FROM grouped WHERE state = 'pending')
GROUP BY grp
ORDER BY MIN(created_at) DESC`

const unseenImportFailuresQuery = `
SELECT COUNT(*) FROM jobs j JOIN users u ON u.id = j.user_id
WHERE j.kind = 'ingest' AND j.user_id = $1 AND j.state = 'failed' AND j.finished_at > u.imports_seen_at
  AND j.seen_at IS NULL`

const unseenImportFailuresListQuery = `
SELECT j.id, j.payload->>'source', COALESCE(j.payload->>'source_detail', ''), j.error_code, j.finished_at
FROM jobs j JOIN users u ON u.id = j.user_id
WHERE j.kind = 'ingest' AND j.user_id = $1 AND j.state = 'failed' AND j.finished_at > u.imports_seen_at
  AND j.seen_at IS NULL
ORDER BY j.finished_at DESC, j.id DESC
LIMIT $2`

// importTitle is what an import is called wherever a person sees it — the Upload menu and the
// /sync page Android's Sync history opens: an uploaded file's name, or, for a phone sync, its source, since the job's own
// file name there is a platform id never meant to be read.
func importTitle(l *i18n.Localizer, source, filename string) string {
	switch {
	case source == "upload" || source == "takeout":
		return filename
	default:
		return sourceLabel(l, source)
	}
}

// sourceLabel names an import source: "Health Connect", "GPS Logger", "Google Takeout"…
func sourceLabel(l *i18n.Localizer, source string) string {
	switch source {
	case "upload", "takeout", "healthconnect", "healthkit", "recorded", "timeline":
		return l.T("imports.source." + source)
	default:
		return source
	}
}

// handleActiveUploads serves `GET /v2/uploads/active`: the imports still being processed, and
// the failures the account hasn't seen yet.
func (s *Server) handleActiveUploads(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	userID := userIDFromContext(ctx)
	l := i18n.Get(requestLang(r))

	rows, err := s.pool.Query(ctx, activeImportsQuery, userID)
	if err != nil {
		s.log.Error("active imports query failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	defer rows.Close()
	resp := activeImportsResponse{Imports: make([]activeImport, 0), Failures: make([]importFailure, 0)}
	for rows.Next() {
		var a activeImport
		var filename string
		if err := rows.Scan(&a.Source, &filename, &a.Done, &a.Total, &a.SubmittedAt); err != nil {
			s.log.Error("active imports scan failed", "err", err)
			writeAPIError(w, "internal error", http.StatusInternalServerError)
			return
		}
		a.Title = importTitle(l, a.Source, filename)
		resp.Imports = append(resp.Imports, a)
	}
	if err := rows.Err(); err != nil {
		s.log.Error("active imports read failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	// The demo account can't dismiss a failure (every write is refused), so it lists none.
	if authInfoFromContext(ctx).isDemo {
		w.Header().Set("Cache-Control", "no-store")
		writeJSON(w, http.StatusOK, resp)
		return
	}
	if err := s.pool.QueryRow(ctx, unseenImportFailuresQuery, userID).Scan(&resp.UnseenFailures); err != nil {
		s.log.Error("unseen import failures query failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	if resp.Failures, err = s.unseenFailures(r, l, userID); err != nil {
		s.log.Error("unseen import failures list failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, resp)
}

// unseenFailures is the newest maxListedFailures failed imports the account hasn't seen, each
// with its reason in l's language. A failure stored without a code (a job abandoned before
// codes existed) reads as ours, never as last_error's English diagnostic.
func (s *Server) unseenFailures(r *http.Request, l *i18n.Localizer, userID string) ([]importFailure, error) {
	rows, err := s.pool.Query(r.Context(), unseenImportFailuresListQuery, userID, maxListedFailures)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]importFailure, 0)
	for rows.Next() {
		var f importFailure
		var source, filename string
		var code *string
		if err := rows.Scan(&f.ID, &source, &filename, &code, &f.FinishedAt); err != nil {
			return nil, err
		}
		if code == nil {
			internal := ingest.FailInternal
			code = &internal
		}
		f.Title = importTitle(l, source, filename)
		f.Reason = jobErrorMessage(l, code, nil)
		out = append(out, f)
	}
	return out, rows.Err()
}

type uploadsSeenRequest struct {
	ID int64 `json:"id"`
}

// handleUploadsSeen serves `POST /v2/uploads/seen`: one of the Upload menu's failures was
// dismissed. Only that one: a failure the menu hasn't shown yet stays listed. An id that isn't
// one of the account's failed imports changes nothing.
func (s *Server) handleUploadsSeen(w http.ResponseWriter, r *http.Request) {
	var req uploadsSeenRequest
	if err := decodeJSON(r.Body, &req); err != nil {
		writeAPIError(w, bodyError(err, "invalid request body"), http.StatusBadRequest)
		return
	}
	if _, err := s.pool.Exec(r.Context(), `
		UPDATE jobs SET seen_at = NOW()
		WHERE id = $1 AND user_id = $2 AND kind = 'ingest' AND state = 'failed' AND seen_at IS NULL`,
		req.ID, userIDFromContext(r.Context())); err != nil {
		s.log.Error("mark import seen failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// markImportsSeen moves the account's imports_seen_at to now: every failure so far has been
// seen. Opening /sync does it.
func (s *Server) markImportsSeen(r *http.Request, userID string) error {
	_, err := s.pool.Exec(r.Context(), `UPDATE users SET imports_seen_at = NOW() WHERE id = $1`, userID)
	return err
}

// newBatchID names one request's jobs as a batch (ingest.Job.Batch). An empty id — random bytes
// unavailable — only means those jobs show as separate rows in the Upload menu.
func newBatchID() string {
	id, err := randomToken()
	if err != nil {
		return ""
	}
	return id
}
