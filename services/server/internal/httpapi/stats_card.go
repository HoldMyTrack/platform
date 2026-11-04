package httpapi

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strconv"

	"github.com/jackc/pgx/v5"

	"github.com/HoldMyTrack/platform/services/server/internal/i18n"
	"github.com/HoldMyTrack/platform/services/server/internal/statscard"
	"github.com/HoldMyTrack/platform/services/server/internal/web"
)

// maxStatsCardSide is the largest image side a card is laid out for: MapLibre's canvas cap,
// past which no client draws an image (IMPLEMENTATION.md §4.3.3).
const maxStatsCardSide = 4096

type statsCardRequest struct {
	ActivityIDs []string        `json:"activity_ids"`
	Width       int             `json:"width"`
	Height      int             `json:"height"`
	Theme       statscard.Theme `json:"theme"`
}

const statsCardQuery = `
SELECT activity_type, distance_meters, COALESCE(moving_seconds, duration_seconds), elevation_gain_m,
       trajectory IS NULL, edit_pending
  FROM activities
 WHERE user_id = $1 AND id = ANY($2::uuid[])
 ORDER BY started_at DESC, id DESC`

// handleStatsCard draws the stats card for a map image export (SPEC FR-4.10): the checked
// activities' numbers as a PNG the client lays over its image. Every id must be the account's;
// Pending ones are left out, and with none left there is no card (204).
func (s *Server) handleStatsCard(w http.ResponseWriter, r *http.Request) {
	var req statsCardRequest
	if err := decodeJSON(r.Body, &req); err != nil {
		writeAPIError(w, bodyError(err, "invalid request body"), http.StatusBadRequest)
		return
	}
	ids, ok := validateActivityIDs(w, req.ActivityIDs, true)
	if !ok {
		return
	}
	if req.Width < 1 || req.Height < 1 || req.Width > maxStatsCardSide || req.Height > maxStatsCardSide {
		writeAPIError(w, fmt.Sprintf("width and height must be 1 to %d", maxStatsCardSide), http.StatusBadRequest)
		return
	}
	if req.Theme != statscard.Light && req.Theme != statscard.Dark {
		writeAPIError(w, `theme must be "light" or "dark"`, http.StatusBadRequest)
		return
	}
	if limited(w, r, s.statsCardLimiter, "error.stats_card_rate_limit") {
		return
	}

	ctx := r.Context()
	acts, country, err := s.statsCardActivities(ctx, userIDFromContext(ctx), ids)
	if errors.Is(err, errActivityNotFound) {
		writeAPIError(w, err.Error(), http.StatusNotFound)
		return
	}
	if err != nil {
		s.statsCardFailed(w, r, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	if len(acts) == 0 {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	card := statscard.Values(acts, i18n.Get(requestLang(r)), web.Imperial(country))
	png, err := statscard.Render(card, req.Width, req.Height, req.Theme)
	if err != nil {
		s.statsCardFailed(w, r, err)
		return
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Content-Length", strconv.Itoa(len(png)))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(png)
}

// statsCardActivities is the card's rows of ids, newest first, Pending ones left out, and the
// account's country; errActivityNotFound when any id isn't the account's.
func (s *Server) statsCardActivities(ctx context.Context, userID string, ids []string) ([]statscard.Activity, string, error) {
	var country string
	if err := s.pool.QueryRow(ctx, `SELECT COALESCE(country, '') FROM users WHERE id = $1`, userID).Scan(&country); err != nil {
		return nil, "", err
	}
	rows, err := s.pool.Query(ctx, statsCardQuery, userID, ids)
	if err != nil {
		return nil, "", err
	}
	type row struct {
		a       statscard.Activity
		pending bool
	}
	found, err := pgx.CollectRows(rows, func(rr pgx.CollectableRow) (row, error) {
		var x row
		err := rr.Scan(&x.a.Type, &x.a.DistanceMeters, &x.a.MovingSeconds, &x.a.ElevationGainM, &x.a.Private, &x.pending)
		return x, err
	})
	if err != nil {
		return nil, "", err
	}
	if len(found) != len(ids) {
		return nil, "", errActivityNotFound
	}
	acts := make([]statscard.Activity, 0, len(found))
	for _, x := range found {
		if !x.pending {
			acts = append(acts, x.a)
		}
	}
	return acts, country, nil
}

func (s *Server) statsCardFailed(w http.ResponseWriter, r *http.Request, err error) {
	if clientGone(w, r) {
		return
	}
	s.log.Error("stats card failed", "err", err)
	writeAPIError(w, "internal error", http.StatusInternalServerError)
}
