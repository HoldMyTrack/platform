package httpapi

import (
	"errors"
	"io"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/HoldMyTrack/platform/services/server/internal/i18n"
	"github.com/HoldMyTrack/platform/services/server/internal/ingest"
	"github.com/HoldMyTrack/platform/services/server/internal/metrics"
)

// maxUploadBytes bounds an uploaded file, which handleUpload reads into memory before the
// worker streams it from object storage (IMPLEMENTATION.md §5.1). A track of a few hours is
// a few MB of GPX or TCX and far less as FIT; only a day or more recorded once a second as GPX
// or TCX comes near this, and such a file has to be split or sent as FIT.
const maxUploadBytes = 16 << 20 // 16 MiB

// maxUploadBodyBytes is an upload's whole multipart body: the file and 1 MiB of overhead.
// ParseMultipartForm keeps all of it in memory, so no upload is written to a temp file.
const maxUploadBodyBytes = maxUploadBytes + 1<<20

// uploadExts is the track file types an upload may be. A `.zip` is refused with a message
// of its own: archives aren't imported (ADR-0039).
var uploadExts = map[string]bool{".gpx": true, ".fit": true, ".tcx": true}

type uploadResponse struct {
	Status     string `json:"status"` // "enqueued" | "already_processed"
	ExternalID string `json:"external_id"`
	Filename   string `json:"filename"`
}

// handleUpload is §4.1 step 1 only: check the file (checkUpload), then enqueue an `ingest` job
// carrying the raw payload (ingest.EnqueueRaw), return. The rest happens in internal/ingest,
// run by cmd/holdmytrack work.
func (s *Server) handleUpload(w http.ResponseWriter, r *http.Request) {
	// Before the body is read, so a refused request costs no memory. Every request counts,
	// a refused or already-imported file too.
	if !s.uploadLimiter.allow(userIDFromContext(r.Context())) {
		httpErrorT(w, r, http.StatusTooManyRequests, "error.upload_rate_limit", "max", s.uploadLimiter.limit)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxUploadBodyBytes)
	if err := r.ParseMultipartForm(maxUploadBodyBytes); err != nil {
		httpErrorT(w, r, http.StatusRequestEntityTooLarge, "error.upload_too_large")
		return
	}
	defer r.MultipartForm.RemoveAll() //nolint:errcheck // best effort; net/http also cleans up
	file, header, err := r.FormFile("file")
	if err != nil {
		httpErrorT(w, r, http.StatusBadRequest, "error.upload_missing")
		return
	}
	defer file.Close()

	ext := strings.ToLower(filepath.Ext(header.Filename))
	if ext == ".zip" {
		httpErrorT(w, r, http.StatusUnsupportedMediaType, "error.upload_zip")
		return
	}
	if !uploadExts[ext] {
		httpErrorT(w, r, http.StatusUnsupportedMediaType, "error.upload_type", "type", strconv.Quote(ext))
		return
	}

	// Refused rather than cut off at the limit, which would have been ingested as a file
	// that ends mid-track, or reported as unreadable.
	if header.Size > maxUploadBytes {
		httpErrorT(w, r, http.StatusRequestEntityTooLarge, "error.upload_too_large")
		return
	}
	// Read once into memory (bounded by maxUploadBytes above) so the same bytes can be
	// hashed and then uploaded with a known Content-Length. See the maxUploadBytes doc
	// comment for why this is a deliberate, bounded exception to "never buffer a file."
	data, err := io.ReadAll(io.LimitReader(file, maxUploadBytes))
	if err != nil {
		httpErrorT(w, r, http.StatusBadRequest, "error.upload_read")
		return
	}
	if len(data) == 0 {
		httpErrorT(w, r, http.StatusBadRequest, "error.upload_empty")
		return
	}
	if s.refuseOverLimit(w, r, userIDFromContext(r.Context()), int64(len(data))) {
		return
	}
	// A file imported already is answered before it is parsed.
	if done, err := ingest.Processed(r.Context(), s.pool, userIDFromContext(r.Context()), "upload", ingest.FileID(data)); err != nil {
		s.log.Error("upload dedupe check failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	} else if done {
		writeJSON(w, http.StatusOK, uploadResponse{Status: "already_processed", ExternalID: ingest.FileID(data), Filename: header.Filename})
		return
	}
	if !s.checkUpload(w, r, header.Filename, ext, data) {
		return
	}

	res, err := ingest.EnqueueRaw(r.Context(), s.pool, userIDFromContext(r.Context()), []ingest.RawItem{
		{Source: "upload", Filename: header.Filename, Ext: ext, Data: data},
	})
	if err != nil {
		s.log.Error("upload enqueue failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	if res[0].AlreadyProcessed {
		writeJSON(w, http.StatusOK, uploadResponse{Status: "already_processed", ExternalID: res[0].ExternalID, Filename: header.Filename})
		return
	}
	writeJSON(w, http.StatusAccepted, uploadResponse{Status: "enqueued", ExternalID: res[0].ExternalID, Filename: header.Filename})
}

// SetUploadsPerHour replaces the per-account upload limit (defaultUploadsPerHour), starting
// every account's count afresh.
func (s *Server) SetUploadsPerHour(n int) {
	s.uploadLimiter = newFixedWindowLimiter(n, time.Hour)
}

// checkUpload runs ingest.CheckFile on an uploaded file and refuses it with its reason, so an
// accepted file always becomes a track (SPEC.md FR-3.1). It reports whether the file passed.
//
// Parsing holds the file's points beside its bytes, about 30 MiB and a quarter of a second for
// a 200,000-point GPX, so s.fileChecks lets one upload per CPU parse at a time. Each waiting
// one holds its body, up to 17 MiB, so past s.fileWaits more are refused as busy: every client
// sends one file at a time, so only many accounts at once reach it.
func (s *Server) checkUpload(w http.ResponseWriter, r *http.Request, filename, ext string, data []byte) bool {
	// A busy refusal is ours, so it doesn't count against the account's hourly uploads.
	busy := func() bool {
		s.uploadLimiter.refund(userIDFromContext(r.Context()))
		httpErrorT(w, r, http.StatusTooManyRequests, "error.upload_busy")
		return false
	}
	select {
	case s.fileWaits <- struct{}{}:
	default:
		return busy()
	}
	defer func() { <-s.fileWaits }()
	select {
	case s.fileChecks <- struct{}{}:
	case <-r.Context().Done():
		return busy() // the client left, or the server is stopping: answered all the same
	}
	err := func() error {
		defer func() { <-s.fileChecks }()
		return ingest.CheckFile(filename, data)
	}()
	if err == nil {
		return true
	}
	code := s.refused(err, strings.TrimPrefix(ext, "."))
	writeError(w, http.StatusUnprocessableEntity, refusalCode(err, code), refusalMessage(i18n.Get(requestLang(r)), err, code))
	return false
}

// refused counts and logs a file or synced track ingest.Check refused, and returns its
// ingest.FailureCode. The log names what it came from, never the file.
func (s *Server) refused(err error, from string) string {
	code := ingest.FailureCode(err)
	metrics.IngestRefused.WithLabelValues(code, from).Inc()
	s.log.Info("track refused", "reason", code, "from", from, "err", err)
	return code
}

// refusalCode is the response's error code: the type's own as a track edit sends it, else the
// failure code.
func refusalCode(err error, code string) string {
	if errors.Is(err, ingest.ErrTypeTooLong) {
		return "track_type_too_long"
	}
	return code
}

// refusalMessage is why a file or synced track was refused, in l's language: the message the
// import history shows for the same failure, or for a type, the one a track edit gets.
func refusalMessage(l *i18n.Localizer, err error, code string) string {
	if errors.Is(err, ingest.ErrTypeTooLong) {
		return l.T("error.track_type_too_long", "max", ingest.MaxTrackTypeLen)
	}
	return l.T("ingest_error." + code)
}
