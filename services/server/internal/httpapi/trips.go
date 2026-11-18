package httpapi

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/HoldMyTrack/platform/services/server/internal/fog"

	"github.com/HoldMyTrack/platform/services/server/internal/tracktype"
)

// Stories (IMPLEMENTATION.md §4.23) — hand-picked, private sets of tracks, each
// with a name, a description and joint statistics. Stored in trips and story_activities
// (§3.19). Another account's Story answers exactly like a missing one, `404`, on every route.
//
// Every change to which tracks a Story holds bumps the account's tile version
// (fog.BumpMapVersion, §4.2.6) in the same transaction: the tracks tiles take a `story`
// filter, so a cached `?story=` tile would otherwise keep showing the old membership. A
// rename or a new description changes no tile and doesn't bump.

const (
	maxTripNameLen        = 200
	maxTripDescriptionLen = 2000
	// maxTripTrackIDs bounds one request's activity_ids — "Create trip" sends every
	// checked track, which with select-all can be a whole history, so this is generous.
	maxTripTrackIDs = 10000
)

var (
	errTripNotFound  = errors.New("story not found")
	errTrackNotFound = errors.New("activity not found")
)

// tripTypeStats is one track type's share of a Story's statistics. MovingSeconds falls
// back to duration_seconds per track, as Trends does (trackTrendsQuery), for tracks
// ingested before moving_seconds was populated.
type tripTypeStats struct {
	TrackType string `json:"activity_type"`
	// Label is the type's name in the request's language (internal/tracktype), set as the
	// Story is written out (withTypeLabels).
	Label          string  `json:"label"`
	Count          int64   `json:"count"`
	DistanceMeters float64 `json:"distance_meters"`
	MovingSeconds  int64   `json:"moving_seconds"`
	ElapsedSeconds int64   `json:"elapsed_seconds"`
}

// tripStats is a Story's joint statistics over its tracks, with no date bound, plus the
// same per track type, most frequent first.
type tripStats struct {
	Count          int64           `json:"count"`
	DistanceMeters float64         `json:"distance_meters"`
	MovingSeconds  int64           `json:"moving_seconds"`
	ElapsedSeconds int64           `json:"elapsed_seconds"`
	ByType         []tripTypeStats `json:"by_type"`
}

type trip struct {
	ID          string    `json:"id"`
	Name        string    `json:"name"`
	Description *string   `json:"description"`
	CreatedAt   time.Time `json:"created_at"`
	UpdatedAt   time.Time `json:"updated_at"`
	// From names who sent the copy this Story came from (§4.23, ADR-0036), while the Story it
	// was copied from still exists; null for a Story of the account's own.
	From *string `json:"from"`
	// Every member, oldest track first — what the Edit window's Stories tab checks its
	// boxes from without a request per Story.
	TrackIDs []string  `json:"activity_ids"`
	Stats    tripStats `json:"stats"`
}

// withTypeLabels names each of the Story's types in lang.
func (st *trip) withTypeLabels(lang string) {
	for i := range st.Stats.ByType {
		st.Stats.ByType[i].Label = tracktype.Label(st.Stats.ByType[i].TrackType, lang)
	}
}

type tripsResponse struct {
	Trips []trip `json:"stories"`
}

// tripRequest is POST's body; PATCH reads the same fields but activity_ids, a full replace
// of name and description, the same one-form shape handleUpdateTrack uses.
type tripRequest struct {
	Name        string   `json:"name"`
	Description string   `json:"description"`
	TrackIDs    []string `json:"activity_ids"`
}

type tripTracksRequest struct {
	TrackIDs []string `json:"activity_ids"`
}

// validateTripFields trims name and description in place and writes a 400 for a value out of
// bounds, reporting whether they're valid.
func validateTripFields(w http.ResponseWriter, r *http.Request, name, description *string) bool {
	*name = strings.TrimSpace(*name)
	*description = strings.TrimSpace(*description)
	switch {
	case *name == "":
		httpErrorT(w, r, http.StatusBadRequest, "error.story_name_required")
	case len([]rune(*name)) > maxTripNameLen:
		httpErrorT(w, r, http.StatusBadRequest, "error.story_name_too_long", "max", maxTripNameLen)
	case len([]rune(*description)) > maxTripDescriptionLen:
		httpErrorT(w, r, http.StatusBadRequest, "error.story_description_too_long", "max", maxTripDescriptionLen)
	default:
		return true
	}
	return false
}

// validateTrackIDs dedupes ids and writes a 400 for a malformed one or too many, reporting
// whether they're valid. required rejects an empty list, which the membership routes have no
// use for.
func validateTrackIDs(w http.ResponseWriter, ids []string, required bool) ([]string, bool) {
	if required && len(ids) == 0 {
		writeAPIError(w, "activity_ids must not be empty", http.StatusBadRequest)
		return nil, false
	}
	if len(ids) > maxTripTrackIDs {
		writeAPIError(w, "too many activity_ids", http.StatusBadRequest)
		return nil, false
	}
	seen := make(map[string]bool, len(ids))
	out := make([]string, 0, len(ids))
	for _, id := range ids {
		if !uuidPattern.MatchString(id) {
			writeAPIError(w, "invalid activity id", http.StatusBadRequest)
			return nil, false
		}
		id = strings.ToLower(id)
		if !seen[id] {
			seen[id] = true
			out = append(out, id)
		}
	}
	return out, true
}

// tripIDFromPath reads {id}, writing a 404 for one that isn't a UUID — it can't be a Story.
func tripIDFromPath(w http.ResponseWriter, r *http.Request) (string, bool) {
	id := r.PathValue("id")
	if !uuidPattern.MatchString(id) {
		writeAPIError(w, errTripNotFound.Error(), http.StatusNotFound)
		return "", false
	}
	return id, true
}

// handleListTrips serves `GET /v1/stories`, newest first.
func (s *Server) handleListTrips(w http.ResponseWriter, r *http.Request) {
	trips, err := s.loadTrips(r.Context(), s.pool, userIDFromContext(r.Context()), nil)
	if s.writeTripError(w, r, err) {
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	for i := range trips {
		trips[i].withTypeLabels(requestLang(r))
	}
	writeJSON(w, http.StatusOK, tripsResponse{Trips: trips})
}

// handleGetTrip serves `GET /v1/stories/{id}`.
func (s *Server) handleGetTrip(w http.ResponseWriter, r *http.Request) {
	id, ok := tripIDFromPath(w, r)
	if !ok {
		return
	}
	st, err := s.loadTrip(r.Context(), s.pool, userIDFromContext(r.Context()), id)
	if s.writeTripError(w, r, err) {
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	st.withTypeLabels(requestLang(r))
	writeJSON(w, http.StatusOK, st)
}

// handleCreateTrip serves `POST /v1/stories`, responding 201 with the new Story. The
// optional activity_ids become its first members in the same transaction, so "Create trip"
// is one request; any of them that isn't the caller's own track fails the whole request
// with a 404 and creates nothing.
func (s *Server) handleCreateTrip(w http.ResponseWriter, r *http.Request) {
	var req tripRequest
	if err := decodeJSON(r.Body, &req); err != nil {
		writeAPIError(w, bodyError(err, "invalid request body"), http.StatusBadRequest)
		return
	}
	if !validateTripFields(w, r, &req.Name, &req.Description) {
		return
	}
	ids, ok := validateTrackIDs(w, req.TrackIDs, false)
	if !ok {
		return
	}
	userID := userIDFromContext(r.Context())

	var created trip
	err := s.inTx(r.Context(), func(tx pgx.Tx) error {
		var id string
		if err := tx.QueryRow(r.Context(), `
			INSERT INTO stories (user_id, name, description) VALUES ($1, $2, NULLIF($3, ''))
			RETURNING id
		`, userID, req.Name, req.Description).Scan(&id); err != nil {
			return err
		}
		added, err := addTripTracks(r.Context(), tx, userID, id, ids)
		if err != nil {
			return err
		}
		if added {
			if err := fog.BumpMapVersion(r.Context(), tx, userID); err != nil {
				return err
			}
		}
		created, err = s.loadTrip(r.Context(), tx, userID, id)
		return err
	})
	if s.writeTripError(w, r, err) {
		return
	}
	created.withTypeLabels(requestLang(r))
	writeJSON(w, http.StatusCreated, created)
}

// handleUpdateTrip serves `PATCH /v1/stories/{id}` — name and description, both sent every
// time; an empty description clears it.
func (s *Server) handleUpdateTrip(w http.ResponseWriter, r *http.Request) {
	id, ok := tripIDFromPath(w, r)
	if !ok {
		return
	}
	var req tripRequest
	if err := decodeJSON(r.Body, &req); err != nil {
		writeAPIError(w, bodyError(err, "invalid request body"), http.StatusBadRequest)
		return
	}
	if !validateTripFields(w, r, &req.Name, &req.Description) {
		return
	}
	userID := userIDFromContext(r.Context())

	tag, err := s.pool.Exec(r.Context(), `
		UPDATE stories SET name = $3, description = NULLIF($4, ''), updated_at = NOW()
		WHERE id = $1 AND user_id = $2
	`, id, userID, req.Name, req.Description)
	if err == nil && tag.RowsAffected() == 0 {
		err = errTripNotFound
	}
	if s.writeTripError(w, r, err) {
		return
	}
	st, err := s.loadTrip(r.Context(), s.pool, userID, id)
	if s.writeTripError(w, r, err) {
		return
	}
	st.withTypeLabels(requestLang(r))
	writeJSON(w, http.StatusOK, st)
}

// handleDeleteTrip serves `DELETE /v1/stories/{id}`, responding 204. Its tracks stay;
// only the memberships cascade away.
func (s *Server) handleDeleteTrip(w http.ResponseWriter, r *http.Request) {
	id, ok := tripIDFromPath(w, r)
	if !ok {
		return
	}
	if s.writeTripError(w, r, s.deleteTrip(r.Context(), userIDFromContext(r.Context()), id)) {
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// deleteTrip deletes userID's Story, errTripNotFound when it isn't theirs.
func (s *Server) deleteTrip(ctx context.Context, userID, id string) error {
	return s.inTx(ctx, func(tx pgx.Tx) error {
		// RETURNING reads the statement's own snapshot, before the cascade removes the
		// memberships, so it says whether the Story held anything.
		var hadTracks bool
		if err := tx.QueryRow(ctx, `
			DELETE FROM stories WHERE id = $1 AND user_id = $2
			RETURNING EXISTS (SELECT 1 FROM story_activities WHERE story_id = $1)
		`, id, userID).Scan(&hadTracks); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return errTripNotFound
			}
			return err
		}
		if hadTracks {
			return fog.BumpMapVersion(ctx, tx, userID)
		}
		return nil
	})
}

// handleAddTripTracks serves `POST /v1/stories/{id}/activities` with `{activity_ids}`,
// responding with the updated Story. An track already in the Story is left as it is; one
// that isn't the caller's own fails the whole request with a 404 and adds nothing.
func (s *Server) handleAddTripTracks(w http.ResponseWriter, r *http.Request) {
	s.changeTripTracks(w, r, addTripTracks)
}

// handleRemoveTripTracks serves `DELETE /v1/stories/{id}/activities` with
// `{activity_ids}`, responding with the updated Story. An id that isn't in the Story is
// ignored. The tracks themselves stay.
func (s *Server) handleRemoveTripTracks(w http.ResponseWriter, r *http.Request) {
	s.changeTripTracks(w, r, func(ctx context.Context, tx pgx.Tx, _, tripID string, ids []string) (bool, error) {
		tag, err := tx.Exec(ctx, `DELETE FROM story_activities WHERE story_id = $1 AND activity_id = ANY($2::uuid[])`,
			tripID, ids)
		return tag.RowsAffected() > 0, err
	})
}

// changeTripTracks is the two membership routes' shared shape: lock the caller's Story
// (a 404 when it isn't theirs), apply change, and bump updated_at and the tile version when
// change reports that the membership actually changed.
func (s *Server) changeTripTracks(w http.ResponseWriter, r *http.Request,
	change func(ctx context.Context, tx pgx.Tx, userID, tripID string, ids []string) (bool, error)) {
	tripID, ok := tripIDFromPath(w, r)
	if !ok {
		return
	}
	var req tripTracksRequest
	if err := decodeJSON(r.Body, &req); err != nil {
		writeAPIError(w, bodyError(err, "invalid request body"), http.StatusBadRequest)
		return
	}
	ids, ok := validateTrackIDs(w, req.TrackIDs, true)
	if !ok {
		return
	}
	ctx := r.Context()
	userID := userIDFromContext(ctx)

	var updated trip
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		var found string
		if err := tx.QueryRow(ctx, `SELECT id FROM stories WHERE id = $1 AND user_id = $2 FOR UPDATE`,
			tripID, userID).Scan(&found); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return errTripNotFound
			}
			return err
		}
		changed, err := change(ctx, tx, userID, tripID, ids)
		if err != nil {
			return err
		}
		if changed {
			if _, err := tx.Exec(ctx, `UPDATE stories SET updated_at = NOW() WHERE id = $1`, tripID); err != nil {
				return err
			}
			if err := fog.BumpMapVersion(ctx, tx, userID); err != nil {
				return err
			}
		}
		updated, err = s.loadTrip(ctx, tx, userID, tripID)
		return err
	})
	if s.writeTripError(w, r, err) {
		return
	}
	updated.withTypeLabels(requestLang(r))
	writeJSON(w, http.StatusOK, updated)
}

// addTripTracks adds ids to the Story, all or none: errTrackNotFound when any of them
// isn't one of userID's tracks. FOR KEY SHARE holds those tracks until commit, so a
// concurrent delete waits rather than failing the insert's foreign key.
func addTripTracks(ctx context.Context, tx pgx.Tx, userID, tripID string, ids []string) (bool, error) {
	if len(ids) == 0 {
		return false, nil
	}
	rows, err := tx.Query(ctx, `SELECT id FROM activities WHERE user_id = $1 AND id = ANY($2::uuid[]) FOR KEY SHARE`,
		userID, ids)
	if err != nil {
		return false, err
	}
	owned, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return false, err
	}
	if len(owned) != len(ids) {
		return false, errTrackNotFound
	}
	tag, err := tx.Exec(ctx, `
		INSERT INTO story_activities (story_id, activity_id)
		SELECT $1, unnest($2::uuid[])
		ON CONFLICT DO NOTHING
	`, tripID, ids)
	return tag.RowsAffected() > 0, err
}

func (s *Server) inTx(ctx context.Context, fn func(pgx.Tx) error) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck // no-op once committed
	if err := fn(tx); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// querier is the common surface of the pool and a transaction, so a Story can be read back
// inside the transaction that just changed it.
type querier interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

// loadTrip is loadTrips for one Story, errTripNotFound when it isn't userID's.
func (s *Server) loadTrip(ctx context.Context, q querier, userID, tripID string) (trip, error) {
	trips, err := s.loadTrips(ctx, q, userID, &tripID)
	if err != nil {
		return trip{}, err
	}
	if len(trips) == 0 {
		return trip{}, errTripNotFound
	}
	return trips[0], nil
}

const listTripsQuery = `
SELECT id, name, description, created_at, updated_at,
       (SELECT ` + senderNameSQL + ` FROM story_copies sc
        JOIN stories src ON src.id = sc.source_story_id
        JOIN users u ON u.id = src.user_id
        WHERE sc.copy_story_id = stories.id
        ORDER BY sc.source_story_id LIMIT 1)
FROM stories
WHERE user_id = $1 AND ($2::uuid IS NULL OR id = $2)
ORDER BY created_at DESC, id DESC`

const tripMembersQuery = `
SELECT sa.story_id, sa.activity_id
FROM story_activities sa
JOIN stories s ON s.id = sa.story_id
JOIN activities a ON a.id = sa.activity_id
WHERE s.user_id = $1 AND ($2::uuid IS NULL OR s.id = $2)
ORDER BY a.started_at, a.id`

// tripStatsQuery is every Story's statistics per track type in one pass; loadTrips
// sums the types into each Story's totals.
const tripStatsQuery = `
SELECT sa.story_id, a.activity_type, COUNT(*),
       COALESCE(SUM(a.distance_meters), 0)::float8,
       COALESCE(SUM(COALESCE(a.moving_seconds, a.duration_seconds)), 0),
       COALESCE(SUM(a.duration_seconds), 0)
FROM story_activities sa
JOIN stories s ON s.id = sa.story_id
JOIN activities a ON a.id = sa.activity_id
WHERE s.user_id = $1 AND ($2::uuid IS NULL OR s.id = $2)
GROUP BY sa.story_id, a.activity_type
ORDER BY COUNT(*) DESC, a.activity_type`

// loadTrips reads userID's Stories — every one, or only tripID's when it's set — with
// their members and statistics: three queries, whatever the number of Stories.
func (s *Server) loadTrips(ctx context.Context, q querier, userID string, tripID *string) ([]trip, error) {
	rows, err := q.Query(ctx, listTripsQuery, userID, tripID)
	if err != nil {
		return nil, err
	}
	trips, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (trip, error) {
		st := trip{TrackIDs: []string{}, Stats: tripStats{ByType: []tripTypeStats{}}}
		err := row.Scan(&st.ID, &st.Name, &st.Description, &st.CreatedAt, &st.UpdatedAt, &st.From)
		return st, err
	})
	if err != nil {
		return nil, err
	}
	if len(trips) == 0 {
		return []trip{}, nil
	}
	byID := make(map[string]*trip, len(trips))
	for i := range trips {
		byID[trips[i].ID] = &trips[i]
	}

	rows, err = q.Query(ctx, tripMembersQuery, userID, tripID)
	if err != nil {
		return nil, err
	}
	var sid, aid string
	if _, err := pgx.ForEachRow(rows, []any{&sid, &aid}, func() error {
		if st := byID[sid]; st != nil {
			st.TrackIDs = append(st.TrackIDs, aid)
		}
		return nil
	}); err != nil {
		return nil, err
	}

	rows, err = q.Query(ctx, tripStatsQuery, userID, tripID)
	if err != nil {
		return nil, err
	}
	var t tripTypeStats
	if _, err := pgx.ForEachRow(rows, []any{&sid, &t.TrackType, &t.Count, &t.DistanceMeters, &t.MovingSeconds, &t.ElapsedSeconds}, func() error {
		st := byID[sid]
		if st == nil {
			return nil
		}
		st.Stats.ByType = append(st.Stats.ByType, t)
		st.Stats.Count += t.Count
		st.Stats.DistanceMeters += t.DistanceMeters
		st.Stats.MovingSeconds += t.MovingSeconds
		st.Stats.ElapsedSeconds += t.ElapsedSeconds
		return nil
	}); err != nil {
		return nil, err
	}
	return trips, nil
}

// writeTripError maps a Story handler's error to a response, reporting whether it wrote one.
func (s *Server) writeTripError(w http.ResponseWriter, r *http.Request, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, errTripNotFound), errors.Is(err, errTrackNotFound):
		writeAPIError(w, err.Error(), http.StatusNotFound)
	case clientGone(w, r):
	default:
		s.log.Error("story request failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
	}
	return true
}
