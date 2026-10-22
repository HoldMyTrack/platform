package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	_ "image/jpeg" // image.DecodeConfig for an uploaded JPEG
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	_ "golang.org/x/image/webp" // image.DecodeConfig for an uploaded WebP

	"github.com/HoldMyTrack/platform/services/server/internal/ingest"
)

// Activity photos (IMPLEMENTATION.md §4.27, ADR-0024) — the user's own pictures on an
// activity, each placed on its route. Stored in activity_photos (§3.22), the images under
// photos/{userID}/ in object storage. The browser resizes a photo and strips its EXIF before
// upload, sending the capture time and position it read as fields; the server keeps a moment on
// the track (route_at), never a position, and works the position out on every read. Every photo
// has one: a photo the server can't place is refused until the user says where it goes.
//
// Another account's photo or activity answers exactly like a missing one, `404`.

const (
	// The resized copy is at most 2048 px on its long side (the web's photoPrep.ts) and a
	// thumbnail 320 px. The limits leave room for another client's slightly different choice,
	// and refuse an original sent as it is: HoldMyTrack is not a photo backup.
	maxPhotoBytes      = 3 << 20 // 3 MiB
	maxPhotoThumbBytes = 256 << 10
	maxPhotoSide       = 2560
	maxPhotoThumbSide  = 640
	// maxPhotosPerAccount bounds the one storage line that grows with how many pictures someone
	// takes rather than how far they go (VISION.md §4.3) — not to monetise, but so one account
	// can't become a material share of the bill (§5.7).
	maxPhotosPerAccount = 2000
	maxPhotoCaptionLen  = 500
	// photoTimeSlack is how far before a track starts or after it ends a capture time still
	// places a photo, at that end — the picture at the trailhead before pressing Start.
	photoTimeSlack = 5 * time.Minute
	// photoSnapMaxM is how far from the track a photo's EXIF position may be and still place
	// it, when its capture time can't. Further off, it was taken somewhere else.
	photoSnapMaxM = 500
)

var allowedPhotoContentType = map[string]string{
	"image/jpeg": "jpeg",
	"image/webp": "webp",
}

var (
	errPhotoNotFound    = errors.New("photo not found")
	errPhotoNoTrack     = errors.New("activity has no track")
	errPhotoInvalidJSON = errors.New("invalid request body")
)

// photoNeedsPlaceCode is the error code of an upload the server couldn't place (photoNeedsPlace):
// the client asks the user where on the track it was taken and sends it again with route_at.
const photoNeedsPlaceCode = "photo_needs_place"

// photoKey is where a newly uploaded photo's image goes, and the image_key its row records. A
// copy of the photo in a copied Story (§4.23) keeps the original's key, so the key, not the
// row's owner and id, names the files from then on.
func photoKey(userID, photoID string) string { return "photos/" + userID + "/" + photoID }

// photoThumbKey is the thumbnail stored beside the image at imageKey.
func photoThumbKey(imageKey string) string { return imageKey + "-thumb" }

// photoJSON is one photo as every photo endpoint returns it. Lon/Lat are null only for an
// activity with no track left at all.
type photoJSON struct {
	ID         string     `json:"id"`
	ActivityID string     `json:"activity_id"`
	TakenAt    *time.Time `json:"taken_at"`
	RouteAt    time.Time  `json:"route_at"`
	// Timezone is its activity's (§4.30), which a client shows TakenAt and RouteAt in.
	Timezone string   `json:"timezone"`
	Lon      *float64 `json:"lon"`
	Lat      *float64 `json:"lat"`
	Caption  *string  `json:"caption"`
	Width    int      `json:"width"`
	Height   int      `json:"height"`
	URL      string   `json:"url"`
	ThumbURL string   `json:"thumb_url"`
}

type photosResponse struct {
	Photos []photoJSON `json:"photos"`
}

// photoSelect reads photos with their place on the map, in route order. The position is
// route_at's point on the trajectory — its M axis is epoch seconds (§3.3) — with route_at
// clamped to the track's own span, so a moment Edit track or a Private location has since cut
// away sits at the visible track's nearest end rather than nowhere: a photo is always on the
// track as it's drawn. That is also why no Private location check is needed here — the cut
// ends are gone from the trajectory, and a track that merely passes through one is drawn whole
// (VISION.md §7), so a photo on it shows nothing the track doesn't. %s is the rest of the WHERE
// clause; $1 is always the owner.
const photoSelect = `
SELECT p.id, p.activity_id, p.taken_at, p.route_at, a.timezone, p.caption, p.width, p.height,
       ST_X(pos.pt), ST_Y(pos.pt)
FROM activity_photos p
JOIN activities a ON a.id = p.activity_id
LEFT JOIN LATERAL (
	SELECT ST_GeometryN(ST_LocateAlong(a.trajectory,
	       LEAST(GREATEST(extract(epoch FROM p.route_at)::float8, ST_M(ST_StartPoint(a.trajectory))),
	             ST_M(ST_EndPoint(a.trajectory)))), 1) AS pt
	WHERE a.trajectory IS NOT NULL
) pos ON true
WHERE p.user_id = $1 AND %s
ORDER BY p.route_at, p.created_at`

func (s *Server) loadPhotos(ctx context.Context, where string, args ...any) ([]photoJSON, error) {
	rows, err := s.pool.Query(ctx, fmt.Sprintf(photoSelect, where), args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	photos := []photoJSON{}
	for rows.Next() {
		var p photoJSON
		if err := rows.Scan(&p.ID, &p.ActivityID, &p.TakenAt, &p.RouteAt, &p.Timezone, &p.Caption, &p.Width, &p.Height, &p.Lon, &p.Lat); err != nil {
			return nil, err
		}
		p.URL = apiPrefix + "/photos/" + p.ID
		p.ThumbURL = p.URL + "/thumb"
		photos = append(photos, p)
	}
	return photos, rows.Err()
}

func (s *Server) loadPhoto(ctx context.Context, userID, photoID string) (photoJSON, error) {
	photos, err := s.loadPhotos(ctx, "p.id = $2", userID, photoID)
	if err != nil {
		return photoJSON{}, err
	}
	if len(photos) == 0 {
		return photoJSON{}, errPhotoNotFound
	}
	return photos[0], nil
}

// handleListPhotos serves `GET /v1/photos?activity={id}` — one activity's photos — and
// `?story={id}`, the photos of every live activity in a Story (§4.23), for its map.
func (s *Server) handleListPhotos(w http.ResponseWriter, r *http.Request) {
	userID := userIDFromContext(r.Context())
	ctx := r.Context()
	q := r.URL.Query()
	var where, id string
	var owns func(context.Context, string, string) (bool, error)
	switch {
	case q.Get("activity") != "":
		id, owns = q.Get("activity"), s.ownsActivity
		where = "p.activity_id = $2"
	case q.Get("story") != "":
		id, owns = q.Get("story"), s.ownsStory
		where = `p.activity_id IN (SELECT activity_id FROM story_activities WHERE story_id = $2)`
	default:
		writeAPIError(w, `missing "activity" or "story"`, http.StatusBadRequest)
		return
	}
	if ok, err := owns(ctx, userID, id); err != nil {
		if clientGone(w, r) {
			return
		}
		s.log.Error("photo list: owner lookup failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	} else if !ok {
		writeAPIError(w, "not found", http.StatusNotFound)
		return
	}
	photos, err := s.loadPhotos(ctx, where, userID, id)
	if err != nil {
		if clientGone(w, r) {
			return
		}
		s.log.Error("photo list failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, photosResponse{Photos: photos})
}

func (s *Server) ownsActivity(ctx context.Context, userID, activityID string) (bool, error) {
	if !uuidPattern.MatchString(activityID) {
		return false, nil
	}
	var ok bool
	err := s.pool.QueryRow(ctx,
		`SELECT EXISTS(SELECT 1 FROM activities WHERE id = $1 AND user_id = $2)`, activityID, userID,
	).Scan(&ok)
	return ok, err
}

func (s *Server) ownsStory(ctx context.Context, userID, storyID string) (bool, error) {
	if !uuidPattern.MatchString(storyID) {
		return false, nil
	}
	var ok bool
	err := s.pool.QueryRow(ctx,
		`SELECT EXISTS(SELECT 1 FROM stories WHERE id = $1 AND user_id = $2)`, storyID, userID,
	).Scan(&ok)
	return ok, err
}

// photoPart is one uploaded image, checked.
type photoPart struct {
	data          []byte
	contentType   string
	width, height int
}

// readPhotoPart reads multipart field name and checks it the way setAvatar checks an avatar —
// the content type sniffed, never the client's claim, since it's what the image is served back
// as — plus that it decodes as that type and is no larger than maxSide on its long side.
func readPhotoPart(r *http.Request, name string, maxBytes int64, maxSide int) (photoPart, error) {
	file, _, err := r.FormFile(name)
	if err != nil {
		return photoPart{}, accountFailure(http.StatusBadRequest, "error.photo_missing")
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, maxBytes+1))
	if err != nil {
		return photoPart{}, accountFailure(http.StatusBadRequest, "error.photo_missing")
	}
	if int64(len(data)) > maxBytes {
		return photoPart{}, accountFailure(http.StatusRequestEntityTooLarge, "error.photo_too_large")
	}
	contentType := http.DetectContentType(data)
	format, ok := allowedPhotoContentType[contentType]
	if !ok {
		return photoPart{}, accountFailure(http.StatusUnsupportedMediaType, "error.photo_type", "type", strconv.Quote(contentType))
	}
	cfg, decoded, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil || decoded != format {
		return photoPart{}, accountFailure(http.StatusUnsupportedMediaType, "error.photo_type", "type", strconv.Quote(contentType))
	}
	if cfg.Width <= 0 || cfg.Height <= 0 || cfg.Width > maxSide || cfg.Height > maxSide {
		return photoPart{}, accountFailure(http.StatusUnprocessableEntity, "error.photo_dimensions", "max", maxSide)
	}
	return photoPart{data: data, contentType: contentType, width: cfg.Width, height: cfg.Height}, nil
}

// handleUploadPhoto serves `POST /v1/photos` — multipart: `activity_id`; `file`, the resized
// copy, and `thumb`, its thumbnail; and what the browser read from the original's EXIF before
// resizing, all optional: `taken_at` (RFC 3339, when the file says its time zone or carries a
// GPS time) or `taken_local` (`2006-01-02T15:04:05`, a camera clock with no zone), and
// `lat`/`lon`; `route_at` (RFC 3339), where on the track the user put it; and `caption`. Answers 201 with
// the photo, placed by placePhoto. One it can't place is refused with 422 and the error code
// photo_needs_place, and the client sends it again with the user's `route_at`.
func (s *Server) handleUploadPhoto(w http.ResponseWriter, r *http.Request) {
	userID := userIDFromContext(r.Context())
	ctx := r.Context()

	r.Body = http.MaxBytesReader(w, r.Body, maxPhotoBytes+maxPhotoThumbBytes+1<<20) // +1MiB of multipart overhead
	if err := r.ParseMultipartForm(maxPhotoBytes + maxPhotoThumbBytes); err != nil {
		s.writeAccountError(w, r, "photo upload", accountFailure(http.StatusRequestEntityTooLarge, "error.photo_too_large"))
		return
	}
	activityID := r.FormValue("activity_id")
	if ok, err := s.ownsActivity(ctx, userID, activityID); err != nil {
		s.log.Error("photo upload: activity lookup failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	} else if !ok {
		writeAPIError(w, "activity not found", http.StatusNotFound)
		return
	}

	var count int
	if err := s.pool.QueryRow(ctx, `SELECT count(*) FROM activity_photos WHERE user_id = $1`, userID).Scan(&count); err != nil {
		s.log.Error("photo upload: count failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	if count >= maxPhotosPerAccount {
		httpErrorT(w, r, http.StatusConflict, "error.photo_limit", "max", maxPhotosPerAccount)
		return
	}

	photo, err := readPhotoPart(r, "file", maxPhotoBytes, maxPhotoSide)
	if err != nil {
		s.writeAccountError(w, r, "photo upload", err)
		return
	}
	thumb, err := readPhotoPart(r, "thumb", maxPhotoThumbBytes, maxPhotoThumbSide)
	if err != nil {
		s.writeAccountError(w, r, "photo upload", err)
		return
	}

	caption, ok := photoCaption(w, r, r.FormValue("caption"))
	if !ok {
		return
	}
	takenAt, routeAt, ok := s.placeFromFields(w, r, activityID, r.FormValue)
	if !ok {
		return
	}

	// The row first, for its id, and committed only once both images are stored — a failed Put
	// leaves no row pointing at an image that isn't there.
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		s.log.Error("photo upload: begin failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	defer tx.Rollback(ctx)
	// The count above turns most uploads past the limit away before the images are read; this
	// one, under a per-account lock held to commit, is what holds when several uploads race
	// past it together. An advisory lock rather than the users row, which a render's tile
	// version bump also writes.
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext('activity_photos:' || $1))`, userID); err != nil {
		s.log.Error("photo upload: lock failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM activity_photos WHERE user_id = $1`, userID).Scan(&count); err != nil {
		s.log.Error("photo upload: count failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	if count >= maxPhotosPerAccount {
		httpErrorT(w, r, http.StatusConflict, "error.photo_limit", "max", maxPhotosPerAccount)
		return
	}
	var photoID, imageKey string
	if err := tx.QueryRow(ctx, `
		WITH n AS (SELECT gen_random_uuid() AS id)
		INSERT INTO activity_photos (id, user_id, activity_id, taken_at, route_at, caption, content_type, thumb_content_type, width, height, bytes, image_key)
		SELECT n.id, $1::uuid, $2, $3, $4, $5, $6, $7, $8, $9, $10, 'photos/' || $1::uuid::text || '/' || n.id FROM n
		RETURNING id, image_key
	`, userID, activityID, takenAt, routeAt, caption, photo.contentType, thumb.contentType, photo.width, photo.height,
		len(photo.data)+len(thumb.data)).Scan(&photoID, &imageKey); err != nil {
		s.log.Error("photo upload: insert failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	if err := s.store.Put(ctx, imageKey, bytes.NewReader(photo.data), int64(len(photo.data))); err != nil {
		s.log.Error("photo upload: store failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	if err := s.store.Put(ctx, photoThumbKey(imageKey), bytes.NewReader(thumb.data), int64(len(thumb.data))); err != nil {
		s.log.Error("photo upload: thumbnail store failed", "err", err)
		s.removePhotoFiles(ctx, imageKey)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	if err := tx.Commit(ctx); err != nil {
		s.log.Error("photo upload: commit failed", "err", err)
		s.removePhotoFiles(ctx, imageKey)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}

	p, err := s.loadPhoto(ctx, userID, photoID)
	if err != nil {
		s.log.Error("photo upload: read back failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusCreated, p)
}

// photoCaption trims a caption, empty meaning none, refusing one over maxPhotoCaptionLen with a
// 400 it writes itself.
func photoCaption(w http.ResponseWriter, r *http.Request, caption string) (*string, bool) {
	trimmed := strings.TrimSpace(caption)
	if trimmed == "" {
		return nil, true
	}
	if utf8.RuneCountInString(trimmed) > maxPhotoCaptionLen {
		httpErrorT(w, r, http.StatusBadRequest, "error.photo_caption_too_long", "max", maxPhotoCaptionLen)
		return nil, false
	}
	return &trimmed, true
}

// handleGetPhoto serves `GET /v1/photos/{id}` and handleGetPhotoThumb `…/thumb` — the stored
// image, to its owner only. A photo's images never change under its id, so they cache for good.
func (s *Server) handleGetPhoto(w http.ResponseWriter, r *http.Request) {
	s.servePhotoImage(w, r, false)
}

func (s *Server) handleGetPhotoThumb(w http.ResponseWriter, r *http.Request) {
	s.servePhotoImage(w, r, true)
}

func (s *Server) servePhotoImage(w http.ResponseWriter, r *http.Request, thumb bool) {
	userID := userIDFromContext(r.Context())
	ctx := r.Context()
	photoID := r.PathValue("id")
	if !uuidPattern.MatchString(photoID) {
		writeAPIError(w, "photo not found", http.StatusNotFound)
		return
	}
	var contentType, thumbContentType, key string
	err := s.pool.QueryRow(ctx,
		`SELECT content_type, thumb_content_type, image_key FROM activity_photos WHERE id = $1 AND user_id = $2`, photoID, userID,
	).Scan(&contentType, &thumbContentType, &key)
	if errors.Is(err, pgx.ErrNoRows) {
		writeAPIError(w, "photo not found", http.StatusNotFound)
		return
	}
	if err != nil {
		s.log.Error("photo lookup failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	if thumb {
		key, contentType = photoThumbKey(key), thumbContentType
	}
	obj, err := s.store.Get(ctx, key)
	if err != nil {
		s.log.Error("photo read failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	defer obj.Close()
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Cache-Control", "private, max-age=31536000, immutable")
	if _, err := io.Copy(w, obj); err != nil {
		s.log.Error("photo stream failed", "err", err)
	}
}

// handleUpdatePhoto serves `PATCH /v1/photos/{id}`. Each field is optional and only a field
// present changes: `caption` (empty clears it), and `route_at` — RFC 3339, the photo's new
// moment on the track (the Edit window's slider), clamped to the track. A photo can't be taken
// off the track: null is refused.
func (s *Server) handleUpdatePhoto(w http.ResponseWriter, r *http.Request) {
	userID := userIDFromContext(r.Context())
	ctx := r.Context()
	photoID := r.PathValue("id")
	if !uuidPattern.MatchString(photoID) {
		writeAPIError(w, "photo not found", http.StatusNotFound)
		return
	}
	var req map[string]json.RawMessage
	if err := json.NewDecoder(io.LimitReader(r.Body, 64<<10)).Decode(&req); err != nil {
		writeAPIError(w, errPhotoInvalidJSON.Error(), http.StatusBadRequest)
		return
	}
	if msg, ok := unknownField(req, "caption", "route_at"); ok {
		writeAPIError(w, msg, http.StatusBadRequest)
		return
	}

	var activityID string
	err := s.pool.QueryRow(ctx,
		`SELECT activity_id FROM activity_photos WHERE id = $1 AND user_id = $2`, photoID, userID,
	).Scan(&activityID)
	if errors.Is(err, pgx.ErrNoRows) {
		writeAPIError(w, "photo not found", http.StatusNotFound)
		return
	}
	if err != nil {
		s.log.Error("photo update: lookup failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}

	// Both fields are checked before either is written, and then written together: a request
	// refused for its route_at must not have changed the caption.
	setCaption, setRouteAt := false, false
	var caption *string
	var routeAt time.Time
	if raw, ok := req["caption"]; ok {
		var in *string
		if err := json.Unmarshal(raw, &in); err != nil {
			writeAPIError(w, errPhotoInvalidJSON.Error(), http.StatusBadRequest)
			return
		}
		value, ok := photoCaption(w, r, deref(in))
		if !ok {
			return
		}
		caption, setCaption = value, true
	}

	if raw, ok := req["route_at"]; ok {
		var at *time.Time
		if err := json.Unmarshal(raw, &at); err != nil || at == nil {
			writeAPIError(w, `invalid "route_at", want an RFC 3339 time`, http.StatusBadRequest)
			return
		}
		start, end, hasTrack, err := s.trackSpan(ctx, activityID)
		if err != nil {
			s.log.Error("photo update: track lookup failed", "err", err)
			writeAPIError(w, "internal error", http.StatusInternalServerError)
			return
		}
		if !hasTrack {
			httpErrorT(w, r, http.StatusConflict, "error.photo_no_track")
			return
		}
		routeAt, setRouteAt = clampToSpan(*at, start, end), true
	}

	if setCaption || setRouteAt {
		if _, err := s.pool.Exec(ctx, `
			UPDATE activity_photos SET
				caption = CASE WHEN $2 THEN $3 ELSE caption END,
				route_at = CASE WHEN $4 THEN $5::timestamptz ELSE route_at END
			WHERE id = $1
		`, photoID, setCaption, caption, setRouteAt, routeAt); err != nil {
			s.log.Error("photo update failed", "err", err)
			writeAPIError(w, "internal error", http.StatusInternalServerError)
			return
		}
	}

	p, err := s.loadPhoto(ctx, userID, photoID)
	if err != nil {
		s.log.Error("photo update: read back failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, p)
}

// handleDeletePhoto serves `DELETE /v1/photos/{id}`: the row, then both images unless another
// row still uses them (a copied Story's photo, §4.23), best-effort — an orphaned blob is a
// cleanup nuisance, never a reason to keep a photo the user removed.
func (s *Server) handleDeletePhoto(w http.ResponseWriter, r *http.Request) {
	userID := userIDFromContext(r.Context())
	ctx := r.Context()
	photoID := r.PathValue("id")
	if !uuidPattern.MatchString(photoID) {
		writeAPIError(w, "photo not found", http.StatusNotFound)
		return
	}
	var imageKey string
	err := s.pool.QueryRow(ctx, `DELETE FROM activity_photos WHERE id = $1 AND user_id = $2 RETURNING image_key`,
		photoID, userID).Scan(&imageKey)
	if errors.Is(err, pgx.ErrNoRows) {
		writeAPIError(w, "photo not found", http.StatusNotFound)
		return
	}
	if err != nil {
		s.log.Error("photo delete failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	s.removeUnreferencedPhotoFiles(ctx, []string{imageKey})
	w.WriteHeader(http.StatusNoContent)
}

// activityPhotoKeys lists an activity's photos' image keys, read before the activity's own delete
// cascades their rows away, so their images can be removed after it.
func (s *Server) activityPhotoKeys(ctx context.Context, activityID string) ([]string, error) {
	rows, err := s.pool.Query(ctx, `SELECT image_key FROM activity_photos WHERE activity_id = $1`, activityID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[string])
}

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

// removePhotoFiles removes a photo's two images, logging rather than failing — for an upload
// that failed before any other row could refer to them.
func (s *Server) removePhotoFiles(ctx context.Context, imageKey string) {
	for _, key := range []string{imageKey, photoThumbKey(imageKey)} {
		if err := s.store.Remove(ctx, key); err != nil {
			s.log.Error("photo object removal failed", "key", key, "err", err)
		}
	}
}

// removeUnreferencedPhotoFiles removes the images at keys that no row uses any more, logging
// rather than failing (ingest.RemoveUnreferencedPhotoFiles).
func (s *Server) removeUnreferencedPhotoFiles(ctx context.Context, keys []string) {
	if err := ingest.RemoveUnreferencedPhotoFiles(ctx, s.pool, s.store, keys); err != nil {
		s.log.Error("photo object removal failed", "err", err)
	}
}
