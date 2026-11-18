package httpapi

import (
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/HoldMyTrack/platform/services/server/internal/i18n"
)

// defaultUploadsLimit matches the upload panel's own page size — 5 rows at a time.
const defaultUploadsLimit = 5

// maxUploadsLimit is a sanity ceiling on the page size a caller can ask for, not a claim that
// this user's real history is ever large enough to need it — see uploadsCountQuery's own
// comment on why LIMIT/OFFSET is fine here despite §4.7's list endpoint dropping pagination.
const maxUploadsLimit = 50

// uploadRow is one entry in the persistent upload history (IMPLEMENTATION.md §4.0), distinct
// from live in-flight status (handleUploadStatus): what happened to every upload, including
// ones whose tab is long closed.
type uploadRow struct {
	Filename   string `json:"filename"`
	ExternalID string `json:"external_id"`
	// The `jobs.payload->>'source'` value — "upload", "healthconnect", "healthkit",
	// "recorded", or "takeout" and "timeline" on jobs from before those imports were removed
	// (§3.3). The clients' Files and Sync lists split rows by it.
	Source      string    `json:"source"`
	Status      string    `json:"status"` // "processing" | "done" | "failed"
	Error       string    `json:"error,omitempty"`
	SubmittedAt time.Time `json:"submitted_at"`
	// When the import finished, "done" or "failed" — when it was synced, from the person's
	// side. Absent while it's still processing.
	FinishedAt *time.Time `json:"finished_at,omitempty"`
	// Populated only when Status == "done" — the frontend shows a finished
	// row as "READY · 11 Sep · 8.2 km" rather than repeating the filename's own status.
	StartedAt      *time.Time `json:"started_at,omitempty"`
	Timezone       *string    `json:"timezone,omitempty"` // StartedAt's zone, where it was recorded (§4.30)
	DistanceMeters *float64   `json:"distance_meters,omitempty"`
	// The resulting track's own id, for a row's "View on map"; absent while the job has no
	// track (still processing, or failed).
	TrackID *string `json:"track_id,omitempty"`
}

type uploadsResponse struct {
	Total int64 `json:"total"`
	// Every pending ingest job of the account, not just this page's, for the panel's "N in
	// progress" badge.
	Processing int64       `json:"processing"`
	Limit      int         `json:"limit"`
	Offset     int         `json:"offset"`
	Uploads    []uploadRow `json:"uploads"`
}

// uploadsCountQuery and uploadsListQuery read the `jobs` table directly rather than a
// dedicated uploads table — every upload already is an `ingest` job (handleUpload), and `jobs` already carries everything a history row needs (filename via
// `payload->>'source_detail'`, external_id, state, last_error, created_at). LIMIT/OFFSET,
// not the keyset pagination §4.7's histogram uses: unlike the track list, an upload log
// only grows, and a caller wants "page 3", not "everything since some cursor."
// The `$2::text[] IS NULL OR ...` treatment is §4.3's own optional-filter pattern
// (track_list.go's listTracksQuery) — an absent/nil sources filter means "every source",
// not "no rows".
const uploadsCountQuery = `
SELECT COUNT(*) FROM jobs
WHERE kind = 'ingest' AND user_id = $1
  AND ($2::text[] IS NULL OR payload->>'source' = ANY($2))`

const uploadsProcessingCountQuery = `SELECT COUNT(*) FROM jobs WHERE kind = 'ingest' AND user_id = $1 AND state = 'pending'`

// The LEFT JOIN is what turns a "done" job into a "9 Sep · 34.7 km" row instead of just a
// bare status. Joined on `a.source = j.payload->>'source'`, not a literal 'upload': every
// source's jobs are `kind = 'ingest'` jobs this query selects, and each one's own persisted
// track carries the matching source, not always 'upload'.
const uploadsListQuery = `
SELECT j.payload->>'source_detail' AS filename,
       j.payload->>'external_id' AS external_id,
       j.payload->>'source' AS source,
       j.state, j.last_error, j.error_code, j.created_at, j.finished_at,
       a.started_at, a.timezone, a.distance_meters, a.id
FROM jobs j
LEFT JOIN tracks a
  ON a.user_id = j.user_id AND a.source = j.payload->>'source' AND a.external_id = j.payload->>'external_id'
WHERE j.kind = 'ingest' AND j.user_id = $1
  AND ($4::text[] IS NULL OR j.payload->>'source' = ANY($4))
ORDER BY j.id DESC
LIMIT $2 OFFSET $3`

// jobErrorMessage is what a failed ingest job shows a person: its error_code's catalog message
// in the reader's language (ingest.FailureCode, IMPLEMENTATION.md §4.21). A failure with no code
// shows last_error as it is; the worker gives every failed ingest job a
// code, so that fallback is only a guard.
func jobErrorMessage(l *i18n.Localizer, errorCode, lastError *string) string {
	if errorCode != nil {
		return l.T("ingest_error." + *errorCode)
	}
	if lastError != nil {
		return *lastError
	}
	return ""
}

// handleListUploads serves §4.0's `GET /v2/uploads?limit=&offset=`.
func (s *Server) handleListUploads(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	limit := defaultUploadsLimit
	if v := q.Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 {
			writeAPIError(w, `invalid "limit", want a positive integer`, http.StatusBadRequest)
			return
		}
		limit = n
	}
	if limit > maxUploadsLimit {
		limit = maxUploadsLimit
	}
	offset := 0
	if v := q.Get("offset"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 0 {
			writeAPIError(w, `invalid "offset", want a non-negative integer`, http.StatusBadRequest)
			return
		}
		offset = n
	}
	// Comma-separated source values (e.g. "upload" for the Files tab,
	// "healthconnect,healthkit,recorded" for Sync) — same convention as §4.3's own `types`
	// filter. Absent means "every source", the unfiltered combined view.
	var sources []string
	if v := q.Get("source"); v != "" {
		sources = strings.Split(v, ",")
	}

	ctx := r.Context()
	userID := userIDFromContext(ctx)

	var total, processing int64
	if err := s.pool.QueryRow(ctx, uploadsCountQuery, userID, sources).Scan(&total); err != nil {
		s.log.Error("uploads count query failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	// Deliberately unfiltered by `sources` — the header badge this feeds counts every
	// in-flight job regardless of which tab is open, so progress never appears to vanish
	// just because the Sync tab happens to be the one on screen.
	if err := s.pool.QueryRow(ctx, uploadsProcessingCountQuery, userID).Scan(&processing); err != nil {
		s.log.Error("uploads processing-count query failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}

	rows, err := s.pool.Query(ctx, uploadsListQuery, userID, limit, offset, sources)
	if err != nil {
		s.log.Error("uploads list query failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	l := i18n.Get(requestLang(r))
	uploads := make([]uploadRow, 0)
	for rows.Next() {
		var u uploadRow
		var state string
		var lastError, errorCode *string
		if err := rows.Scan(&u.Filename, &u.ExternalID, &u.Source, &state, &lastError, &errorCode, &u.SubmittedAt, &u.FinishedAt,
			&u.StartedAt, &u.Timezone, &u.DistanceMeters, &u.TrackID); err != nil {
			s.log.Error("uploads scan failed", "err", err)
			writeAPIError(w, "internal error", http.StatusInternalServerError)
			return
		}
		// Same three-way mapping as handleUploadStatus, duplicated rather than shared:
		// that function reads one job by external_id, this one reads a page of jobs, and
		// factoring out a two-line switch across both would cost more to read than it saves.
		switch state {
		case "pending":
			u.Status = "processing"
		case "done":
			u.Status = "done"
		case "failed":
			u.Status = "failed"
			u.Error = jobErrorMessage(l, errorCode, lastError)
		default:
			u.Status = state
		}
		uploads = append(uploads, u)
	}
	if err := rows.Err(); err != nil {
		s.log.Error("uploads read failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, uploadsResponse{Total: total, Processing: processing, Limit: limit, Offset: offset, Uploads: uploads})
}
