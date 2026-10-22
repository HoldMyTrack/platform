package httpapi

import (
	"context"
	"errors"
	_ "image/jpeg" // image.DecodeConfig for an uploaded JPEG
	"io"
	"math"
	"net/http"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
	_ "golang.org/x/image/webp" // image.DecodeConfig for an uploaded WebP
)

// placeFromFields places a photo from what the client read of its EXIF and where the user put
// it — `taken_at` or `taken_local`, `lat`/`lon`, `route_at`, read through get — writing the
// response itself when it can't: 400 for a field that doesn't parse, 409 for an activity with no
// track, and 422 photo_needs_place when nothing places it. The upload and the placement check
// (handlePlacePhoto) share it, so the check's answer is the upload's.
func (s *Server) placeFromFields(w http.ResponseWriter, r *http.Request, activityID string, get func(string) string) (takenAt, routeAt *time.Time, ok bool) {
	ctx := r.Context()
	clock, err := parsePhotoClock(get("taken_at"), get("taken_local"))
	if err != nil {
		writeAPIError(w, err.Error(), http.StatusBadRequest)
		return nil, nil, false
	}
	at, err := parsePhotoPosition(get("lon"), get("lat"))
	if err != nil {
		writeAPIError(w, err.Error(), http.StatusBadRequest)
		return nil, nil, false
	}
	var chosen *time.Time
	if v := get("route_at"); v != "" {
		t, err := time.Parse(time.RFC3339, v)
		if err != nil {
			writeAPIError(w, `invalid "route_at", want RFC 3339`, http.StatusBadRequest)
			return nil, nil, false
		}
		chosen = &t
	}
	takenAt, routeAt, err = s.placePhoto(ctx, activityID, clock, locationFromContext(ctx), at, chosen)
	if errors.Is(err, errPhotoNoTrack) {
		httpErrorT(w, r, http.StatusConflict, "error.photo_no_track")
		return nil, nil, false
	}
	if err != nil {
		s.log.Error("photo placement failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return nil, nil, false
	}
	if routeAt == nil {
		httpErrorT(w, r, http.StatusUnprocessableEntity, "error.photo_needs_place")
		return nil, nil, false
	}
	return takenAt, routeAt, true
}

// placeRequest is `POST /v1/photos/place`'s body: the upload's placement fields, as JSON.
type placeRequest struct {
	ActivityID string   `json:"activity_id"`
	TakenAt    string   `json:"taken_at"`
	TakenLocal string   `json:"taken_local"`
	Lat        *float64 `json:"lat"`
	Lon        *float64 `json:"lon"`
}

type placeResponse struct {
	RouteAt time.Time  `json:"route_at"`
	TakenAt *time.Time `json:"taken_at"`
}

// handlePlacePhoto serves `POST /v1/photos/place` — where an upload with these fields would be
// placed, storing nothing: `{route_at, taken_at}`, or the upload's own refusals (placeFromFields).
// The Edit window asks it as photos are picked, so it can ask the user about the ones that need a
// place and upload all of them only on Save, each with the place it settled on.
func (s *Server) handlePlacePhoto(w http.ResponseWriter, r *http.Request) {
	userID := userIDFromContext(r.Context())
	var req placeRequest
	if err := decodeJSON(io.LimitReader(r.Body, 16<<10), &req); err != nil {
		writeAPIError(w, bodyError(err, errPhotoInvalidJSON.Error()), http.StatusBadRequest)
		return
	}
	if ok, err := s.ownsActivity(r.Context(), userID, req.ActivityID); err != nil {
		s.log.Error("photo place: activity lookup failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	} else if !ok {
		writeAPIError(w, "activity not found", http.StatusNotFound)
		return
	}
	coord := func(v *float64) string {
		if v == nil {
			return ""
		}
		return strconv.FormatFloat(*v, 'f', -1, 64)
	}
	fields := map[string]string{"taken_at": req.TakenAt, "taken_local": req.TakenLocal, "lat": coord(req.Lat), "lon": coord(req.Lon)}
	takenAt, routeAt, ok := s.placeFromFields(w, r, req.ActivityID, func(k string) string { return fields[k] })
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, placeResponse{RouteAt: *routeAt, TakenAt: takenAt})
}

// photoClock is what the browser read of a photo's capture time: an instant, when the file
// said its zone (or carried a GPS time, which is UTC), or a wall-clock reading with no zone.
type photoClock struct {
	at    *time.Time
	local *time.Time // the wall clock's fields, in time.UTC only as a carrier
}

func parsePhotoClock(takenAt, takenLocal string) (photoClock, error) {
	var c photoClock
	if takenAt != "" {
		t, err := time.Parse(time.RFC3339, takenAt)
		if err != nil {
			return c, errors.New(`invalid "taken_at", want RFC 3339`)
		}
		c.at = &t
	} else if takenLocal != "" {
		t, err := time.Parse("2006-01-02T15:04:05", takenLocal)
		if err != nil {
			return c, errors.New(`invalid "taken_local", want 2006-01-02T15:04:05`)
		}
		c.local = &t
	}
	return c, nil
}

// parsePhotoPosition reads an optional lon/lat pair; one without the other is no position.
func parsePhotoPosition(lonStr, latStr string) (*[2]float64, error) {
	if lonStr == "" || latStr == "" {
		return nil, nil
	}
	lon, err1 := strconv.ParseFloat(lonStr, 64)
	lat, err2 := strconv.ParseFloat(latStr, 64)
	if err1 != nil || err2 != nil || math.Abs(lon) > 180 || math.Abs(lat) > 90 {
		return nil, errors.New(`invalid "lon"/"lat"`)
	}
	return &[2]float64{lon, lat}, nil
}

// trackSpan is an activity's track's first and last moment, epoch seconds; ok is false when
// it has no track.
func (s *Server) trackSpan(ctx context.Context, activityID string) (start, end float64, ok bool, err error) {
	var m0, m1 *float64
	err = s.pool.QueryRow(ctx, `
		SELECT ST_M(ST_StartPoint(trajectory)), ST_M(ST_EndPoint(trajectory)) FROM activities WHERE id = $1
	`, activityID).Scan(&m0, &m1)
	if err != nil || m0 == nil || m1 == nil {
		return 0, 0, false, err
	}
	return *m0, *m1, true, nil
}

// placePhoto works out a new photo's capture time and its moment on the track (ADR-0024). The
// user's own choice (chosen, clamped to the track) wins. Otherwise the capture time places it
// when it falls within the track, photoTimeSlack either side clamped to that end; failing that,
// its EXIF position places it at the nearest point of the track, if that's within
// photoSnapMaxM. With none of these, routeAt is nil: the user has to say. errPhotoNoTrack for an
// activity with no track, which can't hold a photo.
//
// A wall-clock time with no zone is read in the activity's own zone first (§4.30: where the
// camera's clock was, most likely), or the account's (accountLoc) if that one can't be loaded;
// if that misses the track, in whichever UTC offset puts it on the track, the nearest to it.
func (s *Server) placePhoto(ctx context.Context, activityID string, clock photoClock, accountLoc *time.Location, at *[2]float64, chosen *time.Time) (takenAt, routeAt *time.Time, err error) {
	start, end, hasTrack, err := s.trackSpan(ctx, activityID)
	if err != nil {
		return nil, nil, err
	}
	if !hasTrack {
		return nil, nil, errPhotoNoTrack
	}
	onTrack := func(t time.Time) bool { return nearTrack(t, start, end) }

	takenAt = clock.at
	if clock.local != nil {
		home := accountLoc
		var tz string
		if err := s.pool.QueryRow(ctx, `SELECT timezone FROM activities WHERE id = $1`, activityID).Scan(&tz); err != nil {
			return nil, nil, err
		}
		if loc, err := time.LoadLocation(tz); err == nil {
			home = loc
		}
		takenAt = resolveWallClock(*clock.local, home, onTrack)
	}
	if routeAt = photoMoment(start, end, takenAt, chosen); routeAt != nil || at == nil {
		return takenAt, routeAt, nil
	}
	routeAt, err = s.snapToTrack(ctx, activityID, at[0], at[1], photoSnapMaxM)
	return takenAt, routeAt, err
}

// nearTrack reports whether t falls within the track's span (epoch seconds), photoTimeSlack
// either side included.
func nearTrack(t time.Time, start, end float64) bool {
	sec := float64(t.Unix())
	return sec >= start-photoTimeSlack.Seconds() && sec <= end+photoTimeSlack.Seconds()
}

// photoMoment is placePhoto's rule before any position is looked at: the user's choice, else
// the capture time when it is near the track, either clamped to the span; nil when neither
// places the photo.
func photoMoment(start, end float64, takenAt, chosen *time.Time) *time.Time {
	var t time.Time
	switch {
	case chosen != nil:
		t = clampToSpan(*chosen, start, end)
	case takenAt != nil && nearTrack(*takenAt, start, end):
		t = clampToSpan(*takenAt, start, end)
	default:
		return nil
	}
	return &t
}

// clampToSpan puts t within the track's first and last moment (epoch seconds), to the second.
func clampToSpan(t time.Time, start, end float64) time.Time {
	sec := math.Min(math.Max(float64(t.Unix()), start), end)
	return time.Unix(int64(math.Round(sec)), 0).UTC()
}

// resolveWallClock turns a zoneless camera clock into an instant: in home if that lands on
// the track (or nothing does), else in the UTC offset nearest home's that does. Offsets step by
// 15 minutes from −12:00 to +14:00, which covers every zone in use.
func resolveWallClock(local time.Time, home *time.Location, onTrack func(time.Time) bool) *time.Time {
	inHome := time.Date(local.Year(), local.Month(), local.Day(), local.Hour(), local.Minute(), local.Second(), 0, home)
	if onTrack(inHome) {
		return &inHome
	}
	_, homeOffset := inHome.Zone()
	var best *time.Time
	bestDiff := math.MaxInt
	for offset := -12 * 3600; offset <= 14*3600; offset += 15 * 60 {
		t := time.Date(local.Year(), local.Month(), local.Day(), local.Hour(), local.Minute(), local.Second(), 0, time.FixedZone("", offset))
		diff := offset - homeOffset
		if diff < 0 {
			diff = -diff
		}
		if onTrack(t) && diff < bestDiff {
			best, bestDiff = &t, diff
		}
	}
	if best != nil {
		return best
	}
	return &inHome
}

// snapToTrack is the moment of the track's point nearest lon/lat, or nil when that point is
// further than maxM away. ST_InterpolatePoint reads it from the M axis at the nearest point.
func (s *Server) snapToTrack(ctx context.Context, activityID string, lon, lat float64, maxM float64) (*time.Time, error) {
	var m, dist *float64
	err := s.pool.QueryRow(ctx, `
		SELECT ST_InterpolatePoint(trajectory, pt),
		       ST_Distance(ST_Force2D(trajectory)::geography, pt::geography)
		FROM activities, ST_SetSRID(ST_MakePoint($2::float8, $3::float8), 4326) AS pt
		WHERE id = $1 AND trajectory IS NOT NULL
	`, activityID, lon, lat).Scan(&m, &dist)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, errPhotoNoTrack
	}
	if err != nil || m == nil {
		return nil, err
	}
	if dist != nil && *dist > maxM {
		return nil, nil
	}
	t := time.Unix(int64(math.Round(*m)), 0).UTC()
	return &t, nil
}
