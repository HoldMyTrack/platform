package httpapi

import (
	"archive/zip"
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"mime"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/HoldMyTrack/platform/services/server/internal/export"
	"github.com/HoldMyTrack/platform/services/server/internal/ingest"
	"github.com/HoldMyTrack/platform/services/server/internal/zoneinfo"
)

// maxGPXTracks is the most tracks one download takes: a Library page (trackPageSize).
const maxGPXTracks = trackPageSize

// maxGPXPoints bounds the points one download parses, summed over its tracks' originals
// (tracks.raw_points): about a hundred two-hour recordings at one point a second.
const maxGPXPoints = 2_000_000

// gpxTrack is what a download needs of a track before it parses anything.
type gpxTrack struct {
	ID        string
	StartedAt time.Time
	Timezone  string
	Type      string
	Name      string
	Pending   bool
	Private   bool
	Original  bool
	// RawPoints is the original's point count, nil until counted (migration 0064).
	RawPoints *int
}

// label names the track in a refusal: its name, else its type, then its local start.
func (t gpxTrack) label() string {
	start := t.StartedAt.In(zoneinfo.LoadOr(t.Timezone, time.UTC)).Format("2006-01-02 15:04")
	if t.Name != "" {
		return t.Name + " (" + start + ")"
	}
	return t.Type + " (" + start + ")"
}

// parseGPXIDs reads `ids`: track ids, comma-separated, lowercased, each once in the order sent.
func parseGPXIDs(q url.Values) ([]string, error) {
	raw := q.Get("ids")
	if raw == "" {
		return nil, errors.New(`"ids" is required`)
	}
	var ids []string
	seen := map[string]bool{}
	for _, v := range strings.Split(raw, ",") {
		v = strings.ToLower(strings.TrimSpace(v))
		if !uuidPattern.MatchString(v) {
			return nil, errors.New(`invalid "ids", want track ids separated by commas`)
		}
		if !seen[v] {
			seen[v] = true
			ids = append(ids, v)
		}
	}
	return ids, nil
}

// gpxRefusal is why tracks can't be downloaded together, as a message key and the track it
// names, or "" when they can. Each refusal names the first track it applies to, so the client
// can uncheck it; the size is checked last, over the counted tracks (writeGPXDownload counts
// the rest as it parses them).
func gpxRefusal(tracks []gpxTrack) (key string, track *gpxTrack) {
	for i := range tracks {
		t := &tracks[i]
		switch {
		case t.Pending:
			return "error.gpx_pending", t
		case t.Private:
			return "error.gpx_all_private", t
		case !t.Original:
			return "error.gpx_no_original", t
		}
	}
	if gpxPoints(tracks) > maxGPXPoints {
		return "error.gpx_too_large", nil
	}
	return "", nil
}

// gpxPoints is the points the counted tracks' originals hold.
func gpxPoints(tracks []gpxTrack) int {
	n := 0
	for _, t := range tracks {
		if t.RawPoints != nil {
			n += *t.RawPoints
		}
	}
	return n
}

// errGPXTooLarge is a download whose originals, counted as they were parsed, passed maxGPXPoints.
var errGPXTooLarge = errors.New("the tracks' originals hold too many points")

// handleTracksGPX serves `GET /v2/tracks/gpx?ids=` (docs/SPEC.md FR-17.2): the tracks as the map
// shows them, one as a .gpx file and several as a zip of them. Every check that needs no parsing
// runs first, so an oversized or impossible request is refused before any original is read, and
// only a request that passes them counts against the hourly limit; the file is built in a
// temporary file, so a track whose original no longer parses refuses the whole request rather
// than cutting a download short.
func (s *Server) handleTracksGPX(w http.ResponseWriter, r *http.Request) {
	ids, err := parseGPXIDs(r.URL.Query())
	if err != nil {
		writeAPIError(w, err.Error(), http.StatusBadRequest)
		return
	}
	if len(ids) > maxGPXTracks {
		httpErrorT(w, r, http.StatusBadRequest, "error.gpx_too_many", "max", maxGPXTracks)
		return
	}
	ctx := r.Context()
	tracks, err := readRows(ctx, s, `
		SELECT id, started_at, timezone, track_type, COALESCE(name, ''), edit_pending, trajectory IS NULL,
		       raw_payload_key IS NOT NULL, raw_points
		FROM tracks WHERE user_id = $1 AND id = ANY($2::uuid[])
		ORDER BY started_at, id`, func(row rowScanner) (gpxTrack, error) {
		var t gpxTrack
		err := row.Scan(&t.ID, &t.StartedAt, &t.Timezone, &t.Type, &t.Name, &t.Pending, &t.Private, &t.Original, &t.RawPoints)
		return t, err
	}, userIDFromContext(ctx), ids)
	if err != nil {
		if clientGone(w, r) {
			return
		}
		s.log.Error("gpx track lookup failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	if len(tracks) != len(ids) {
		writeAPIError(w, "track not found", http.StatusNotFound)
		return
	}
	switch key, t := gpxRefusal(tracks); {
	case key == "error.gpx_too_large":
		httpErrorT(w, r, http.StatusRequestEntityTooLarge, key, "max", maxGPXPoints)
		return
	case key != "":
		httpErrorT(w, r, http.StatusConflict, key, "track", t.label())
		return
	}
	if limited(w, r, s.gpxLimiter, "error.gpx_rate_limit") {
		return
	}

	f, err := os.CreateTemp("", gpxTempPattern)
	if err != nil {
		s.log.Error("gpx temp file failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	defer os.Remove(f.Name())
	defer f.Close()
	name, contentType, err := s.writeGPXDownload(ctx, f, tracks)
	var te gpxTrackError
	switch {
	case errors.Is(err, errGPXTooLarge):
		httpErrorT(w, r, http.StatusRequestEntityTooLarge, "error.gpx_too_large", "max", maxGPXPoints)
		return
	case errors.Is(err, ingest.ErrTrackNotFound):
		// Deleted since it was looked up.
		writeAPIError(w, "track not found", http.StatusNotFound)
		return
	case errors.As(err, &te):
		s.log.Warn("gpx track not exported", "track_id", te.track.ID, "err", te.err)
		httpErrorT(w, r, http.StatusConflict, te.key, "track", te.track.label())
		return
	case err != nil:
		if clientGone(w, r) {
			return
		}
		s.log.Error("gpx download build failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	size, err := f.Seek(0, io.SeekCurrent)
	if err == nil {
		_, err = f.Seek(0, io.SeekStart)
	}
	if err != nil {
		s.log.Error("gpx temp file failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Content-Disposition", mime.FormatMediaType("attachment", map[string]string{"filename": name}))
	w.Header().Set("Content-Length", strconv.FormatInt(size, 10))
	w.Header().Set("Cache-Control", "no-store")
	if _, err := io.Copy(w, f); err != nil && !clientGone(w, r) {
		s.log.Warn("gpx download send failed", "err", err)
	}
}

// gpxTrackError is a track that turned out not to be exportable once its original was read: the
// refusal's message key, naming the track.
type gpxTrackError struct {
	track *gpxTrack
	key   string
	err   error
}

func (e gpxTrackError) Error() string { return e.track.ID + ": " + e.err.Error() }

// writeGPXDownload writes the tracks into f: one as GPX, several as a zip of GPX files named as
// the data download names them (export.TrackFileBase), and returns the file's name and type. A
// track whose original can't be read back into points is a gpxTrackError, and one gone since
// it was looked up is ingest.ErrTrackNotFound. An uncounted original is counted as it is parsed,
// and stored for the tracks sharing it; once the count passes maxGPXPoints it is errGPXTooLarge.
func (s *Server) writeGPXDownload(ctx context.Context, f io.Writer, tracks []gpxTrack) (name, contentType string, err error) {
	files := map[string]bool{}
	var zw *zip.Writer
	if len(tracks) > 1 {
		zw = zip.NewWriter(f)
	}
	total := gpxPoints(tracks)
	for i := range tracks {
		t := &tracks[i]
		points, rawPoints, err := ingest.DisplayedPointsCounted(ctx, s.pool, s.store, t.ID)
		switch {
		case ctx.Err() != nil:
			return "", "", ctx.Err()
		case errors.Is(err, ingest.ErrTrackNotFound):
			return "", "", err
		case errors.Is(err, ingest.ErrEditPending):
			return "", "", gpxTrackError{t, "error.gpx_pending", err}
		case err != nil:
			return "", "", gpxTrackError{t, "error.gpx_unreadable", err}
		}
		if t.RawPoints == nil {
			s.storeRawPoints(ctx, t.ID, rawPoints)
			if total += rawPoints; total > maxGPXPoints {
				return "", "", errGPXTooLarge
			}
		}
		if points == nil {
			// Its route edit left nothing outside the Private locations.
			return "", "", gpxTrackError{t, "error.gpx_all_private", errors.New("nothing left to show")}
		}
		file := export.UniqueName(files, export.TrackFileBase(t.StartedAt.In(zoneinfo.LoadOr(t.Timezone, time.UTC)), t.Name, t.Type)) + ".gpx"
		if zw == nil {
			return file, "application/gpx+xml", export.WriteGPX(f, t.Type, points)
		}
		entry, err := zw.CreateHeader(&zip.FileHeader{Name: file, Method: zip.Deflate, Modified: time.Now()})
		if err != nil {
			return "", "", err
		}
		if err := export.WriteGPX(entry, t.Type, points); err != nil {
			return "", "", err
		}
	}
	if err := zw.Close(); err != nil {
		return "", "", err
	}
	return fmt.Sprintf("holdmytrack-%d-tracks-%s.zip", len(tracks), time.Now().UTC().Format(dateLayout)), "application/zip", nil
}

// storeRawPoints keeps an original's count, parsed for a download, for the tracks sharing it, so
// the next download checks it before parsing. A failure costs only that.
func (s *Server) storeRawPoints(ctx context.Context, trackID string, n int) {
	if _, err := s.pool.Exec(ctx, `
		UPDATE tracks SET raw_points = $2
		WHERE raw_points IS NULL AND raw_payload_key = (SELECT raw_payload_key FROM tracks WHERE id = $1)`,
		trackID, n); err != nil {
		s.log.Warn("gpx raw_points store failed", "track_id", trackID, "err", err)
	}
}

// gpxTempPattern names a download's temporary file, so removeStaleGPXFiles can find one a crash
// left behind.
const gpxTempPattern = "gpx-download-*"

// removeStaleGPXFiles deletes the temporary files of downloads a crash or restart cut off, which
// hold clipped routes (docs/DPIA.md): those over an hour old, so a download still being built
// by another process sharing the directory is left alone.
func removeStaleGPXFiles(log *slog.Logger) {
	files, err := filepath.Glob(filepath.Join(os.TempDir(), gpxTempPattern))
	if err != nil {
		return
	}
	for _, f := range files {
		if fi, err := os.Stat(f); err == nil && time.Since(fi.ModTime()) > time.Hour {
			if err := os.Remove(f); err != nil {
				log.Warn("stale gpx download not removed", "file", f, "err", err)
			}
		}
	}
}
