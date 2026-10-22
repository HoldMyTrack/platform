package ingest

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/HoldMyTrack/platform/services/server/internal/parse"
	"github.com/HoldMyTrack/platform/services/server/internal/storage"
)

// SplitRange is the stretch of the recorded points one piece of a split activity covers
// (IMPLEMENTATION.md §4.7.8): activities.split_from and split_to, unix milliseconds, both ends
// inclusive, so the two pieces either side of a split share the point it was made at. A nil
// end is that end of the recording; an activity never split has both nil.
type SplitRange struct {
	From *int64
	To   *int64
}

// IsWhole reports whether the range covers the whole recording.
func (r SplitRange) IsWhole() bool { return r.From == nil && r.To == nil }

// contains reports whether a point timestamp lies inside the range.
func (r SplitRange) contains(t int64) bool {
	return (r.From == nil || t >= *r.From) && (r.To == nil || t <= *r.To)
}

// Apply returns the points inside the range, with its ends clipped against zones again. The
// points come in clipped already, but a split made inside a Private location — at home,
// between a ride there and a walk from there — leaves a new end inside it, the same way an
// edit's Chop can (TrackEdit.ApplyClipped).
func (r SplitRange) Apply(points []parse.Point, zones []Zone) []parse.Point {
	if r.IsWhole() {
		return points
	}
	out := make([]parse.Point, 0, len(points))
	for _, p := range points {
		if r.contains(p.Time.UnixMilli()) {
			out = append(out, p)
		}
	}
	return ClipEnds(out, zones)
}

// LoadPiecePoints is loadClippedPoints narrowed to one piece's range — the points the track
// editor shows and the split check counts — plus the zones they were clipped with. Nil points
// when the piece lies entirely inside Private locations.
func LoadPiecePoints(ctx context.Context, pool *pgxpool.Pool, store *storage.Store, userID, sourceDetail, rawKey string, rng SplitRange) ([]parse.Point, []Zone, error) {
	_, points, zones, err := loadClippedPoints(ctx, pool, store, userID, sourceDetail, rawKey)
	if err != nil || points == nil {
		return nil, zones, err
	}
	if points = rng.Apply(points, zones); len(points) < 2 {
		return nil, zones, nil
	}
	return points, zones, nil
}

// ErrSplitTooClose is a split leaving one side with less than a line.
var ErrSplitTooClose = errors.New("a split needs at least two points on each side")

// ErrSplitHidden is a split leaving one side entirely inside Private locations — a part saved
// with no track, as any activity entirely inside them is (FR-8.1), which comes back when the
// location moves. Allowed once the user has been told. Reachable from the editor, whose preview shows the points
// a track edit's second clip (TrackEdit.ApplyClipped) hides: a walk home ending in a stray fix
// outside the circle, that fix deleted, keeps every point inside the circle on show there.
var ErrSplitHidden = errors.New("one side of the split lies inside a private location")

// CheckSplit reports whether splitting at the point timestamped at leaves both pieces a track.
// points are the piece's own clipped points, before the edit. A side with fewer than two
// points once the edit is applied is too close (ErrSplitTooClose); one that has them, but
// loses them when it's worked out the way reprocessActivity will — narrowed to its side of at
// (the point itself on both), clipped against zones, edit applied, clipped again — lies inside
// a Private location (ErrSplitHidden).
func CheckSplit(points []parse.Point, zones []Zone, edit *TrackEdit, at int64) error {
	for _, side := range []SplitRange{{To: &at}, {From: &at}} {
		plain := side.Apply(points, nil)
		if edit != nil {
			plain = edit.Apply(plain)
		}
		if len(plain) < 2 {
			return ErrSplitTooClose
		}
		p := side.Apply(points, zones)
		if edit != nil && len(p) >= 2 {
			p = edit.ApplyClipped(p, zones)
		}
		if len(p) < 2 {
			return ErrSplitHidden
		}
	}
	return nil
}

// ErrSplitConflict is a split point outside the piece's current range.
var ErrSplitConflict = errors.New("this activity can't be split there any more")

// insertSplitPiece is the split half of EnqueueTrackEdit: inside its transaction, with the
// activity already flipped Pending, it narrows the activity to the points up to at and inserts
// a new Pending row for the points from at on, returning the new row's id. The new row copies
// the activity's type, name, description, raw payload and track edit, joins its Stories, and
// takes over the photos placed after at. Its external_id is the original's with a suffix, so
// re-importing the original still finds the original row and stays a no-op.
func insertSplitPiece(ctx context.Context, tx pgx.Tx, userID, activityID string, at int64) (string, error) {
	var from, to *int64
	var rawKey *string
	if err := tx.QueryRow(ctx,
		`SELECT split_from, split_to, raw_payload_key FROM activities WHERE id = $1 AND user_id = $2`,
		activityID, userID,
	).Scan(&from, &to, &rawKey); err != nil {
		return "", err
	}
	if rawKey == nil || (from != nil && at <= *from) || (to != nil && at >= *to) {
		return "", ErrSplitConflict
	}

	var pieceID string
	if err := tx.QueryRow(ctx, `
		INSERT INTO activities (
			user_id, source, source_detail, external_id, activity_type, started_at,
			raw_payload_key, raw_bytes, name, description, track_edit, edit_pending,
			split_group, split_from, split_to, timezone
		)
		SELECT user_id, source, source_detail,
		       CASE WHEN external_id IS NULL THEN NULL
		            ELSE left(split_part(external_id, '#split:', 1), 200) || '#split:' || $3::bigint::text END,
		       activity_type, to_timestamp($3::bigint / 1000.0), raw_payload_key, raw_bytes, name, description,
		       track_edit, true, COALESCE(split_group, id), $3::bigint, split_to, timezone
		FROM activities WHERE id = $1 AND user_id = $2
		RETURNING id
	`, activityID, userID, at).Scan(&pieceID); err != nil {
		return "", fmt.Errorf("insert split piece: %w", err)
	}
	if _, err := tx.Exec(ctx, `
		UPDATE activities SET split_group = COALESCE(split_group, id), split_to = $2 WHERE id = $1
	`, activityID, at); err != nil {
		return "", err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO story_activities (story_id, activity_id)
		SELECT story_id, $2 FROM story_activities WHERE activity_id = $1
	`, activityID, pieceID); err != nil {
		return "", err
	}
	if _, err := tx.Exec(ctx, `
		UPDATE activity_photos SET activity_id = $2
		WHERE activity_id = $1 AND route_at > to_timestamp($3::bigint / 1000.0)
	`, activityID, pieceID, at); err != nil {
		return "", err
	}
	return pieceID, nil
}
