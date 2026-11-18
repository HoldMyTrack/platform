package httpapi

import (
	"bytes"
	"context"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"path"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/HoldMyTrack/platform/services/server/internal/fog"
	"github.com/HoldMyTrack/platform/services/server/internal/ingest"
	"github.com/HoldMyTrack/platform/services/server/internal/storage"
)

// DemoCustomerUserID is the one persistent, shared demo account every "Try Demo" visitor's
// session is pointed at (handleDemoStart) — not a fresh row created and re-seeded per visitor.
// Must match the row migrations/0045_baseline.sql inserts. This id is what makes an account
// the demo (authInfo.isDemo): read-only and exempt from email verification.
const DemoCustomerUserID = "22222222-2222-2222-2222-222222222222"

// demo_data/ holds the account's history as raw track files in any format ingest parses
// (parse.ByExtensionUpTo: .gpx, .tcx, .fit, .json), plus manifest.json. They are real tracks
// on a live deployment, written out as GPX by `export-demo-activities` (demo_export.go)
// exactly as their owner sees them, and reviewed by hand before being committed.
//
//go:embed demo_data
var demoData embed.FS

// demoManifestFile is demo_data/'s one non-track file: what the raw files can't carry
// themselves — per-file overrides (not every file needs one), the account's Trips and its
// Spots captures.
const demoManifestFile = "manifest.json"

// demoManifest is manifest.json: Tracks keyed by filename, Trips naming their
// tracks by filename too, and SpotCaptures.
type demoManifest struct {
	Tracks       map[string]demoManifestEntry `json:"tracks"`
	Trips        []demoManifestTrip           `json:"trips,omitempty"`
	SpotCaptures []demoManifestCapture        `json:"spot_captures,omitempty"`
}

// demoManifestCapture is one place the account has captured (§4.25). A capture belongs to the
// account, not to a track. The place is named by its OSM key, which, unlike spots.id, is
// the same on every deployment that loaded it. Name is only for someone reading the manifest;
// the seed ignores it.
type demoManifestCapture struct {
	OSMType    string    `json:"osm_type"`
	OSMID      int64     `json:"osm_id"`
	Name       string    `json:"name,omitempty"`
	CapturedAt time.Time `json:"captured_at"`
}

// demoManifestTrip is one Trip the seed gives the account (§4.23): a name, a description,
// and its tracks by filename. Trips are matched by name on a re-run. OpensFirst marks the
// one Trip dated newest, which the Trips tab and the tour open (seedDemoTrips).
type demoManifestTrip struct {
	Name        string   `json:"name"`
	Description string   `json:"description,omitempty"`
	Tracks      []string `json:"tracks"`
	OpensFirst  bool     `json:"opens_first,omitempty"`
}

// demoManifestEntry is one file's overrides. Name is the track's display name — no file
// parser sets parse.Activity.Name, so without it the seeded row gets the generic
// "<Type> - <date>" every unnamed track gets. Type is the activity_type, needed for files
// that don't carry their own: a synced track (Health Connect, in-app recording) reports
// its type in the sync request, not inside the JSON payload the export copies out.
// Description is the track's free-text description, which no file carries either.
// Photos are the track's photos (§4.27), their images in demo_data/photos/.
type demoManifestEntry struct {
	Name        string              `json:"name,omitempty"`
	Type        string              `json:"type,omitempty"`
	Description string              `json:"description,omitempty"`
	Photos      []demoManifestPhoto `json:"photos,omitempty"`
}

// demoPhotoDir is the demo_data/ subdirectory the photos' images are in — a directory, so
// demoFiles never mistakes one for a track file.
const demoPhotoDir = "photos"

// demoManifestPhoto is one photo on a demo track: its resized image and thumbnail as stored
// (files in demoPhotoDir, JPEG or WebP by extension), and the activity_photos fields that
// aren't the image itself. RouteAt is a moment on the track's route, which the exported GPX
// keeps the timestamps of, so it lands on the same spot after a re-ingest.
type demoManifestPhoto struct {
	File    string     `json:"file"`
	Thumb   string     `json:"thumb"`
	TakenAt *time.Time `json:"taken_at,omitempty"`
	RouteAt time.Time  `json:"route_at"`
	Caption string     `json:"caption,omitempty"`
	Width   int        `json:"width"`
	Height  int        `json:"height"`
}

// demoPhotoContentType is a demo photo file's content type, from its extension: the two the
// photo endpoints store (allowedPhotoContentType), or "" for anything else.
func demoPhotoContentType(file string) string {
	switch strings.ToLower(path.Ext(file)) {
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".webp":
		return "image/webp"
	}
	return ""
}

// loadDemoManifest reads demo_data/manifest.json. A missing manifest is an empty one; a
// manifest naming a file that isn't there fails — a track entry or a Trip's track
// alike — since that's a typo or a file deleted without its entry, and would otherwise pass
// silently. So does a Trip the API itself would refuse: no name, a name or description over
// the limit, two Trips with one name (a re-run couldn't tell them apart), or no tracks;
// and a capture with no place or time, or two of one place (the table keeps one per place).
func loadDemoManifest(fsys fs.FS, files []string) (demoManifest, error) {
	manifest := demoManifest{Tracks: map[string]demoManifestEntry{}}
	b, err := fs.ReadFile(fsys, demoManifestFile)
	if errors.Is(err, fs.ErrNotExist) {
		return manifest, nil
	}
	if err != nil {
		return demoManifest{}, err
	}
	if err := json.Unmarshal(b, &manifest); err != nil {
		return demoManifest{}, fmt.Errorf("%s: %w", demoManifestFile, err)
	}
	if manifest.Tracks == nil {
		manifest.Tracks = map[string]demoManifestEntry{}
	}
	present := make(map[string]bool, len(files))
	for _, f := range files {
		present[f] = true
	}
	photoFiles := map[string]bool{}
	for f, entry := range manifest.Tracks {
		if !present[f] {
			return demoManifest{}, fmt.Errorf("%s: entry %q has no matching file", demoManifestFile, f)
		}
		for _, p := range entry.Photos {
			for _, img := range []string{p.File, p.Thumb} {
				if demoPhotoContentType(img) == "" {
					return demoManifest{}, fmt.Errorf("%s: %q: photo %q must be .jpg or .webp", demoManifestFile, f, img)
				}
				if photoFiles[img] {
					return demoManifest{}, fmt.Errorf("%s: photo file %q is listed twice", demoManifestFile, img)
				}
				photoFiles[img] = true
				if _, err := fs.Stat(fsys, path.Join(demoPhotoDir, img)); err != nil {
					return demoManifest{}, fmt.Errorf("%s: %q: photo %q has no matching file", demoManifestFile, f, img)
				}
			}
			if p.RouteAt.IsZero() || p.Width <= 0 || p.Height <= 0 {
				return demoManifest{}, fmt.Errorf("%s: %q: photo %q needs route_at, width and height", demoManifestFile, f, p.File)
			}
			if len([]rune(p.Caption)) > maxPhotoCaptionLen {
				return demoManifest{}, fmt.Errorf("%s: %q: photo %q: caption over %d characters", demoManifestFile, f, p.File, maxPhotoCaptionLen)
			}
		}
	}
	names := map[string]bool{}
	opensFirst := 0
	for _, st := range manifest.Trips {
		if st.OpensFirst {
			opensFirst++
		}
		switch {
		case opensFirst > 1:
			return demoManifest{}, fmt.Errorf("%s: story %q: only one story opens first", demoManifestFile, st.Name)
		case strings.TrimSpace(st.Name) == "" || len([]rune(st.Name)) > maxTripNameLen:
			return demoManifest{}, fmt.Errorf("%s: story name %q must be 1–%d characters", demoManifestFile, st.Name, maxTripNameLen)
		case len([]rune(st.Description)) > maxTripDescriptionLen:
			return demoManifest{}, fmt.Errorf("%s: story %q: description over %d characters", demoManifestFile, st.Name, maxTripDescriptionLen)
		case names[st.Name]:
			return demoManifest{}, fmt.Errorf("%s: two stories named %q", demoManifestFile, st.Name)
		case len(st.Tracks) == 0:
			return demoManifest{}, fmt.Errorf("%s: trip %q has no tracks", demoManifestFile, st.Name)
		}
		names[st.Name] = true
		for _, f := range st.Tracks {
			if !present[f] {
				return demoManifest{}, fmt.Errorf("%s: trip %q: track %q has no matching file", demoManifestFile, st.Name, f)
			}
		}
	}
	captured := map[demoManifestCapture]bool{}
	for _, c := range manifest.SpotCaptures {
		key := demoManifestCapture{OSMType: c.OSMType, OSMID: c.OSMID}
		switch {
		case c.OSMType != "node" && c.OSMType != "way" && c.OSMType != "relation":
			return demoManifest{}, fmt.Errorf("%s: capture of %s %d: osm_type must be node, way or relation", demoManifestFile, c.OSMType, c.OSMID)
		case c.OSMID <= 0 || c.CapturedAt.IsZero():
			return demoManifest{}, fmt.Errorf("%s: capture of %s %d needs osm_id and captured_at", demoManifestFile, c.OSMType, c.OSMID)
		case captured[key]:
			return demoManifest{}, fmt.Errorf("%s: %s %d is captured twice", demoManifestFile, c.OSMType, c.OSMID)
		}
		captured[key] = true
	}
	return manifest, nil
}

// demoFiles lists demo_data/'s track files, sorted, failing on any extension ingest can't
// parse — a stray README or .DS_Store would otherwise fail one by one at ingest time, after
// the files sorted ahead of it were already seeded.
func demoFiles(fsys fs.FS) ([]string, error) {
	entries, err := fs.ReadDir(fsys, ".")
	if err != nil {
		return nil, err
	}
	var names []string
	for _, e := range entries {
		if e.IsDir() || e.Name() == demoManifestFile {
			continue
		}
		switch strings.ToLower(path.Ext(e.Name())) {
		case ".gpx", ".tcx", ".fit", ".json":
			names = append(names, e.Name())
		default:
			return nil, fmt.Errorf("unsupported file %q (want .gpx, .tcx, .fit or .json)", e.Name())
		}
	}
	sort.Strings(names)
	return names, nil
}

// SeedDemoCustomer ingests every embedded track file in demo_data/ into DemoCustomerUserID,
// through the same real pipeline (internal/ingest.Process — parse, persist, Fog mask render) a
// real upload uses. Meant to run once, out of band (the `seed-demo-customer` CLI subcommand),
// not per visitor: re-ingesting the whole history on every "Try Demo" click would be far too
// slow. ingest.go's `ON CONFLICT (user_id, source, external_id) DO NOTHING` makes re-running
// this safe: already-ingested files are skipped, not duplicated.
//
// That same skip means a plain re-run never picks up a changed or removed file — reset wipes
// the account's tracks first (resetDemoCustomer), so the seeded history ends up matching
// demo_data/ exactly.
func SeedDemoCustomer(ctx context.Context, pool *pgxpool.Pool, store *storage.Store, log *slog.Logger, reset bool) error {
	fsys, err := fs.Sub(demoData, "demo_data")
	if err != nil {
		return fmt.Errorf("seed demo customer: %w", err)
	}
	names, err := demoFiles(fsys)
	if err != nil {
		return fmt.Errorf("seed demo customer: %w", err)
	}
	manifest, err := loadDemoManifest(fsys, names)
	if err != nil {
		return fmt.Errorf("seed demo customer: %w", err)
	}

	if reset {
		if err := resetDemoCustomer(ctx, pool, store, log); err != nil {
			return fmt.Errorf("seed demo customer: %w", err)
		}
	}

	var ingested, skipped, failed int
	// Each file's track, for the Trips below.
	trackIDs := make(map[string]string, len(names))
	for _, filename := range names {
		b, err := fs.ReadFile(fsys, filename)
		if err != nil {
			log.Error("demo customer seed: read embedded file failed", "err", err, "file", filename)
			failed++
			continue
		}

		ext := path.Ext(filename)
		externalID := "demo-customer-" + strings.TrimSuffix(filename, ext)
		rawKey := "raw/" + DemoCustomerUserID + "/demo-history/" + externalID + ext
		if err := store.Put(ctx, rawKey, bytes.NewReader(b), int64(len(b))); err != nil {
			log.Error("demo customer seed: upload failed", "err", err, "file", filename)
			failed++
			continue
		}

		entry := manifest.Tracks[filename]
		job := ingest.Job{
			UserID:        DemoCustomerUserID,
			Source:        "demo-customer-history",
			SourceDetail:  filename,
			ExternalID:    externalID,
			RawPayloadKey: rawKey,
			RawBytes:      int64(len(b)),
			TrackType:     entry.Type,
		}
		result, err := ingest.Process(ctx, pool, store, job)
		if err != nil {
			log.Error("demo customer seed: ingest failed", "err", err, "file", filename)
			failed++
			continue
		}
		if result.Persisted {
			ingested++
		} else {
			skipped++
		}
		trackIDs[filename] = result.TrackID

		// Applied after every ingest.Process call, whether it persisted a new row or found
		// one already there (ON CONFLICT DO NOTHING still returns the existing row's id) — so
		// re-running the seed always leaves the manifest's names in place, not only the one
		// time a row is first inserted.
		if entry.Name != "" || entry.Description != "" {
			if _, err := pool.Exec(ctx,
				`UPDATE activities SET name = COALESCE(NULLIF($1, ''), name), description = COALESCE(NULLIF($2, ''), description) WHERE id = $3`,
				entry.Name, entry.Description, result.TrackID,
			); err != nil {
				log.Error("demo customer seed: name/description override failed", "err", err, "file", filename)
				failed++
			}
		}
		if err := seedDemoPhotos(ctx, pool, store, fsys, DemoCustomerUserID, result.TrackID, entry.Photos); err != nil {
			log.Error("demo customer seed: photos failed", "err", err, "file", filename)
			failed++
		}
	}

	if failed == 0 {
		if err := seedDemoTrips(ctx, pool, DemoCustomerUserID, manifest.Trips, trackIDs); err != nil {
			return fmt.Errorf("seed demo customer: %w", err)
		}
	}
	missing, err := seedDemoCaptures(ctx, pool, DemoCustomerUserID, manifest.SpotCaptures)
	if err != nil {
		return fmt.Errorf("seed demo customer: %w", err)
	}
	for _, c := range missing {
		log.Warn("demo customer seed: captured place not loaded here, skipped", "osm_type", c.OSMType, "osm_id", c.OSMID, "name", c.Name)
	}

	log.Info("demo customer seed: done", "ingested", ingested, "already_present", skipped, "failed", failed, "total", len(names), "stories", len(manifest.Trips),
		"captures", len(manifest.SpotCaptures)-len(missing))
	if failed > 0 {
		return fmt.Errorf("seed demo customer: %d of %d files failed", failed, len(names))
	}
	return nil
}

// seedDemoPhotos gives a seeded track of userID's (the Demo Customer, but a parameter so
// tests can use their own) the manifest's photos: both images into storage where the photo
// endpoints read them (photoKey, photoThumbKey), and the row. Each photo's id is derived from
// the account and its file name, so a re-run updates the same row and objects rather than
// adding a copy, as it does a track's name.
func seedDemoPhotos(ctx context.Context, pool *pgxpool.Pool, store *storage.Store, fsys fs.FS, userID, trackID string, photos []demoManifestPhoto) error {
	for _, p := range photos {
		var photoID string
		if err := pool.QueryRow(ctx, `SELECT md5('demo-photo/' || $1 || '/' || $2)::uuid::text`, userID, p.File).Scan(&photoID); err != nil {
			return err
		}
		var size int
		for _, img := range []struct{ file, key string }{
			{p.File, photoKey(userID, photoID)},
			{p.Thumb, photoThumbKey(photoKey(userID, photoID))},
		} {
			b, err := fs.ReadFile(fsys, path.Join(demoPhotoDir, img.file))
			if err != nil {
				return err
			}
			if err := store.Put(ctx, img.key, bytes.NewReader(b), int64(len(b))); err != nil {
				return fmt.Errorf("photo %q: %w", img.file, err)
			}
			size += len(b)
		}
		if _, err := pool.Exec(ctx, `
			INSERT INTO activity_photos (id, user_id, activity_id, taken_at, route_at, caption, content_type, thumb_content_type, width, height, bytes, image_key)
			VALUES ($1, $2, $3, $4, $5, NULLIF($6, ''), $7, $8, $9, $10, $11, $12)
			ON CONFLICT (id) DO UPDATE SET activity_id = EXCLUDED.activity_id, taken_at = EXCLUDED.taken_at,
				route_at = EXCLUDED.route_at, caption = EXCLUDED.caption, content_type = EXCLUDED.content_type,
				thumb_content_type = EXCLUDED.thumb_content_type, width = EXCLUDED.width, height = EXCLUDED.height,
				bytes = EXCLUDED.bytes`,
			photoID, userID, trackID, p.TakenAt, p.RouteAt, p.Caption,
			demoPhotoContentType(p.File), demoPhotoContentType(p.Thumb), p.Width, p.Height, size, photoKey(userID, photoID),
		); err != nil {
			return fmt.Errorf("photo %q: %w", p.File, err)
		}
	}
	return nil
}

// seedDemoCaptures gives the account (the Demo Customer, but a parameter so tests can use their
// own) the manifest's captures, each at the manifest's time, so a re-run fixes one that
// drifted. A capture the manifest doesn't name is left alone; --reset is what removes those.
// A place this deployment hasn't loaded (import-spots, §4.25) can't be captured: it's returned
// rather than failing the seed, since a development stack often has no places at all.
func seedDemoCaptures(ctx context.Context, pool *pgxpool.Pool, userID string, captures []demoManifestCapture) ([]demoManifestCapture, error) {
	var missing []demoManifestCapture
	for _, c := range captures {
		tag, err := pool.Exec(ctx, `
			INSERT INTO spot_captures (user_id, spot_id, captured_at)
			SELECT $1, id, $4 FROM spots WHERE osm_type = $2 AND osm_id = $3
			ON CONFLICT (user_id, spot_id) DO UPDATE SET captured_at = EXCLUDED.captured_at`,
			userID, c.OSMType, c.OSMID, c.CapturedAt)
		if err != nil {
			return nil, fmt.Errorf("capture of %s %d: %w", c.OSMType, c.OSMID, err)
		}
		if tag.RowsAffected() == 0 {
			missing = append(missing, c)
		}
	}
	return missing, nil
}

// seedDemoTrips gives the account (the Demo Customer, but a parameter so tests can use their
// own) the manifest's Trips, each matched by name: created if
// it isn't there, and otherwise given the manifest's description and exactly its tracks —
// so a plain re-run fixes a Trip that drifted, as it does a track's name. A Trip the
// manifest doesn't name is left alone; --reset is what removes those. One transaction, and one
// tile-version bump if any Trip's tracks changed (§4.2.6): the tracks tiles take a
// `story` filter.
//
// Each Trip is dated the day after its last track ended, as someone would make one after a
// trip, rather than the moment of the seed: the Trips are listed newest first, so they then
// read in the order they were visited, not the manifest's. The one that opens first is dated
// after its own tracks and a day after every other Trip, so the Trips tab, which opens
// the newest, opens it.
func seedDemoTrips(ctx context.Context, pool *pgxpool.Pool, userID string, trips []demoManifestTrip, trackIDs map[string]string) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("stories: %w", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck // no-op once committed
	changed := false
	first := ""
	for _, st := range trips {
		ids := make([]string, 0, len(st.Tracks))
		for _, f := range st.Tracks {
			ids = append(ids, trackIDs[f])
		}
		var tripID string
		err := tx.QueryRow(ctx, `SELECT id FROM stories WHERE user_id = $1 AND name = $2 ORDER BY created_at LIMIT 1`,
			userID, st.Name).Scan(&tripID)
		switch {
		case errors.Is(err, pgx.ErrNoRows):
			err = tx.QueryRow(ctx, `INSERT INTO stories (user_id, name, description) VALUES ($1, $2, NULLIF($3, '')) RETURNING id`,
				userID, st.Name, st.Description).Scan(&tripID)
		case err == nil:
			_, err = tx.Exec(ctx, `UPDATE stories SET description = NULLIF($2, ''), updated_at = NOW() WHERE id = $1 AND description IS DISTINCT FROM NULLIF($2, '')`,
				tripID, st.Description)
		}
		if err != nil {
			return fmt.Errorf("story %q: %w", st.Name, err)
		}
		removed, err := tx.Exec(ctx, `DELETE FROM story_activities WHERE story_id = $1 AND NOT activity_id = ANY($2::uuid[])`, tripID, ids)
		if err != nil {
			return fmt.Errorf("story %q: %w", st.Name, err)
		}
		added, err := tx.Exec(ctx, `
			INSERT INTO story_activities (story_id, activity_id) SELECT $1, unnest($2::uuid[])
			ON CONFLICT DO NOTHING`, tripID, ids)
		if err != nil {
			return fmt.Errorf("story %q: %w", st.Name, err)
		}
		if removed.RowsAffected() > 0 || added.RowsAffected() > 0 {
			changed = true
		}
		if st.OpensFirst {
			first = tripID
		}
		if _, err := tx.Exec(ctx, `
			UPDATE stories s SET created_at = d.at, updated_at = d.at
			FROM (SELECT MAX(started_at + make_interval(secs => COALESCE(duration_seconds, 0))) + INTERVAL '1 day' AS at
			      FROM activities WHERE id = ANY($2::uuid[])) d
			WHERE s.id = $1 AND (s.created_at IS DISTINCT FROM d.at OR s.updated_at IS DISTINCT FROM d.at)`,
			tripID, ids); err != nil {
			return fmt.Errorf("story %q: %w", st.Name, err)
		}
	}
	// Dated above, by its own tracks, so a later date only ever moves it on.
	if first != "" {
		if _, err := tx.Exec(ctx, `
			UPDATE stories s SET created_at = d.at, updated_at = d.at
			FROM (SELECT MAX(created_at) + INTERVAL '1 day' AS at FROM stories WHERE user_id = $1 AND id <> $2) d
			WHERE s.id = $2 AND d.at > s.created_at`,
			userID, first); err != nil {
			return fmt.Errorf("stories: %w", err)
		}
	}
	if changed {
		if err := fog.BumpMapVersion(ctx, tx, userID); err != nil {
			return fmt.Errorf("stories: %w", err)
		}
	}
	return tx.Commit(ctx)
}

// resetDemoCustomer deletes every track the demo account has, with everything derived from
// them, so the seed that follows starts from nothing. The DB side cascades from tracks
// (tile masks, country/region matches, photos); fog_tiles is per user, not per track, so
// it's deleted explicitly — ingest recreates each row a new track touches, and a row left
// behind would keep a tile only the old history reached. Object storage has no foreign keys,
// so its prefixes are swept first, logging a failure and carrying on.
//
// The worker is quiesced for this account first: a previous seed can leave a render_fog job
// queued behind its ingests, and one already running would rewrite fog_tiles rows (and their
// objects) right after they were deleted. The queued ones are dropped — the seed that follows
// enqueues its own — and a running one is waited out.
func resetDemoCustomer(ctx context.Context, pool *pgxpool.Pool, store *storage.Store, log *slog.Logger) error {
	if err := quiesceDemoJobs(ctx, pool, log); err != nil {
		return fmt.Errorf("reset: %w", err)
	}

	prefixes := []string{"raw/" + DemoCustomerUserID + "/", "fog/" + DemoCustomerUserID + "/", "photos/" + DemoCustomerUserID + "/"}
	for _, prefix := range prefixes {
		if err := store.RemoveByPrefix(ctx, prefix); err != nil {
			log.Error("demo customer reset: storage cleanup failed, deleting rows anyway", "prefix", prefix, "err", err)
		}
	}

	tx, err := pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("reset: begin: %w", err)
	}
	defer tx.Rollback(ctx)
	removed, err := tx.Exec(ctx, `DELETE FROM activities WHERE user_id = $1`, DemoCustomerUserID)
	if err != nil {
		return fmt.Errorf("reset: %w", err)
	}
	for _, q := range []string{
		`DELETE FROM jobs WHERE user_id = $1 AND state = 'pending'`,
		// Its Trips too: the seed recreates the manifest's, and nothing else should survive.
		`DELETE FROM stories WHERE user_id = $1`,
		// And its captures, which belong to the account rather than to a track.
		`DELETE FROM spot_captures WHERE user_id = $1`,
		`DELETE FROM fog_tiles WHERE user_id = $1`,
		// Its tiles are about to be rendered from scratch; nothing cached before this is its.
		`UPDATE users SET map_version = map_version + 1 WHERE id = $1`,
	} {
		if _, err := tx.Exec(ctx, q, DemoCustomerUserID); err != nil {
			return fmt.Errorf("reset: %w", err)
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("reset: commit: %w", err)
	}
	log.Info("demo customer reset: done", "activities_removed", removed.RowsAffected())
	return nil
}

// demoJobLockStale bounds how long quiesceDemoJobs waits on a claimed job: past this, a job
// still claimed but never finished belongs to a worker that died mid-run, not one still going.
const demoJobLockStale = 10 * time.Minute

// quiesceDemoJobs deletes the demo account's unclaimed pending jobs and waits until none is
// running. A claim (internal/worker's claimAndRun) only sets locked_at — the job stays
// 'pending' until it finishes — so a running job is a pending one with a recent locked_at.
func quiesceDemoJobs(ctx context.Context, pool *pgxpool.Pool, log *slog.Logger) error {
	tag, err := pool.Exec(ctx,
		`DELETE FROM jobs WHERE user_id = $1 AND state = 'pending' AND locked_at IS NULL`, DemoCustomerUserID)
	if err != nil {
		return fmt.Errorf("drop queued jobs: %w", err)
	}
	if n := tag.RowsAffected(); n > 0 {
		log.Info("demo customer reset: dropped queued jobs", "jobs", n)
	}
	for waited := false; ; waited = true {
		var running int
		if err := pool.QueryRow(ctx,
			`SELECT count(*) FROM jobs WHERE user_id = $1 AND state = 'pending' AND locked_at > NOW() - make_interval(secs => $2)`,
			DemoCustomerUserID, demoJobLockStale.Seconds(),
		).Scan(&running); err != nil {
			return fmt.Errorf("check running jobs: %w", err)
		}
		if running == 0 {
			return nil
		}
		if !waited {
			log.Info("demo customer reset: waiting for running jobs to finish", "jobs", running)
		}
		select {
		case <-time.After(2 * time.Second):
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}
