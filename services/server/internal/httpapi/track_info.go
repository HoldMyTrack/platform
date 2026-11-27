package httpapi

import (
	"context"
	"errors"
	"net/http"

	"github.com/jackc/pgx/v5"

	"github.com/HoldMyTrack/platform/services/server/internal/i18n"
	"github.com/HoldMyTrack/platform/services/server/internal/trackinfo"
	"github.com/HoldMyTrack/platform/services/server/internal/web"
)

type trackInfoRequest struct {
	TrackIDs []string `json:"track_ids"`
}

const trackInfoQuery = `
SELECT track_type, started_at, timezone, duration_seconds, moving_seconds, distance_meters::float8,
       elevation_gain_m::float8, trajectory IS NULL
  FROM tracks
 WHERE user_id = $1 AND id = ANY($2::uuid[])
 ORDER BY started_at DESC, id DESC`

// handleTrackInfo serves the Tracks toolbar's Info (SPEC FR-5.8): its lines for the toolbar's
// target, formatted here (trackinfo) so every client shows the same text. Every id must be
// the account's.
func (s *Server) handleTrackInfo(w http.ResponseWriter, r *http.Request) {
	var req trackInfoRequest
	if err := decodeJSON(r.Body, &req); err != nil {
		writeAPIError(w, bodyError(err, "invalid request body"), http.StatusBadRequest)
		return
	}
	ids, ok := validateTrackIDs(w, req.TrackIDs, true)
	if !ok {
		return
	}
	if limited(w, r, s.trackInfoLimiter, "error.track_info_rate_limit") {
		return
	}
	ctx := r.Context()
	tracks, country, err := s.trackInfoTracks(ctx, userIDFromContext(ctx), ids)
	if errors.Is(err, errTrackNotFound) {
		writeAPIError(w, err.Error(), http.StatusNotFound)
		return
	}
	if err != nil {
		if clientGone(w, r) {
			return
		}
		s.log.Error("track info failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, trackinfo.Of(tracks, i18n.Get(requestLang(r)), web.Imperial(country)))
}

// trackInfoTracks is ids' rows, newest first, and the account's country; errTrackNotFound when
// any id isn't the account's.
func (s *Server) trackInfoTracks(ctx context.Context, userID string, ids []string) ([]trackinfo.Track, string, error) {
	var country string
	if err := s.pool.QueryRow(ctx, `SELECT COALESCE(country, '') FROM users WHERE id = $1`, userID).Scan(&country); err != nil {
		return nil, "", err
	}
	rows, err := s.pool.Query(ctx, trackInfoQuery, userID, ids)
	if err != nil {
		return nil, "", err
	}
	tracks, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (trackinfo.Track, error) {
		var a trackinfo.Track
		err := row.Scan(&a.Type, &a.StartedAt, &a.Timezone, &a.DurationSeconds, &a.MovingSeconds, &a.DistanceMeters, &a.ElevationGainM, &a.Private)
		return a, err
	})
	if err != nil {
		return nil, "", err
	}
	if len(tracks) != len(ids) {
		return nil, "", errTrackNotFound
	}
	return tracks, country, nil
}
