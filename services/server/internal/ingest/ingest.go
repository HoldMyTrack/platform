// Package ingest is the worker's half of the ingestion pipeline (IMPLEMENTATION.md §4.1): it
// parses an original, applies Private locations, stores the track with its simplified
// display track, and draws the track's own Fog masks (fog.RenderTrackMasks) from the raw
// points while they're in memory, since coverage can't come from the simplified track
// (ARCHITECTURE.md §1.1). Compositing the tiles, and the z13..z0 pyramid above them, is
// internal/fog's, run by a `render_fog` job this package enqueues.
package ingest

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"slices"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/HoldMyTrack/platform/services/server/internal/fog"
	"github.com/HoldMyTrack/platform/services/server/internal/geo"
	"github.com/HoldMyTrack/platform/services/server/internal/parse"
	"github.com/HoldMyTrack/platform/services/server/internal/storage"
	"github.com/HoldMyTrack/platform/services/server/internal/tilemath"
)

// simplifyToleranceDeg is ST_SimplifyPreserveTopology's tolerance for the display trajectory
// (§4.1 step 5), in degrees (the geometry's own units, WGS84). ~0.00003° is roughly 3 m at
// the equator — small enough to preserve trail shape, large enough to matter on long tracks.
const simplifyToleranceDeg = 0.00003

// Job is what the `ingest` job's payload carries — everything the worker needs that isn't
// already in the raw payload itself.
type Job struct {
	UserID        string `json:"user_id"`
	Source        string `json:"source"`
	SourceDetail  string `json:"source_detail"`
	ExternalID    string `json:"external_id"`
	RawPayloadKey string `json:"raw_payload_key"`
	// RawBytes is the size of the object at RawPayloadKey, which every enqueuer knows as it
	// writes it; stored as tracks.raw_bytes for the storage statistics. 0 is unknown (a
	// job enqueued before it existed), stored as NULL.
	RawBytes int64 `json:"raw_bytes,omitempty"`
	// TrackType overrides whatever the parser itself reports, when set. Empty means "use
	// the parsed value". A copy of a Trip (tripcopy) and the demo seed set it: their GPX
	// carries no type of its own, and they already know the track's.
	TrackType string `json:"track_type,omitempty"`
	// Batch groups the jobs one request enqueued together — a phone sync's tracks — so the
	// header's Upload menu can show them as one row however the page was reloaded meanwhile.
	// Empty for a single uploaded file, which is its own row.
	Batch string `json:"batch,omitempty"`
}

// Result reports what happened, distinguishing "persisted a new track" from "this was
// already processed" — IMPLEMENTATION.md §4.0's idempotency invariant: a
// conflict at persist time is a successful no-op, not an error.
type Result struct {
	TrackID   string
	Persisted bool // false means ON CONFLICT DO NOTHING fired: already processed.
}

func Process(ctx context.Context, pool *pgxpool.Pool, store *storage.Store, job Job) (Result, error) {
	// A new file is held to parse.MaxPoints; one kept before the cap is read whole elsewhere.
	act, err := loadRecorded(ctx, store, job.SourceDetail, job.RawPayloadKey, parse.MaxPoints)
	if err != nil {
		return Result{}, err
	}
	// Continuous across the antimeridian, as loadClippedPoints leaves them.
	act.Points = unwrapLons(act.Points)
	zones, err := LoadZones(ctx, pool, job.UserID)
	if err != nil {
		return Result{}, fmt.Errorf("ingest: load private locations: %w", err)
	}
	for attempt := 1; ; attempt++ {
		res, current, err := processClipped(ctx, pool, store, job, act, zones)
		if errors.Is(err, errZonesChanged) && attempt < 3 {
			zones = current // clipped again with the locations read under the lock
			continue
		}
		return res, err
	}
}

// errZonesChanged is the account's Private locations changing between the clip and the save:
// the track is clipped again with the new ones.
var errZonesChanged = errors.New("ingest: Private locations changed while the track was clipped")

// processClipped clips the parsed recording with zones and saves it, unless the account's
// locations changed since zones was read: then errZonesChanged, with the current ones.
func processClipped(ctx context.Context, pool *pgxpool.Pool, store *storage.Store, job Job, act parse.Track, zones []Zone) (Result, []Zone, error) {
	act.Points = slices.Clone(act.Points)
	points := ClipEnds(act.Points, zones)
	res, current, err := persistClipped(ctx, pool, store, job, act, points, zones)
	return res, current, err
}

func persistClipped(ctx context.Context, pool *pgxpool.Pool, store *storage.Store, job Job, act parse.Track, points []parse.Point, zones []Zone) (Result, []Zone, error) {
	var err error
	if job.TrackType != "" {
		act.TrackType = job.TrackType
	}
	// A track entirely inside Private locations is still persisted, just with no geometry:
	// dropping it would lose it for good, even after the location that hides it is deleted.
	hidden := points == nil
	startedAt := act.Points[0].Time
	recStart, recEnd := recordedSpan(act.Points, SplitRange{})

	var pp preparedTrack
	var tiles [][2]int
	if !hidden {
		// Before anything is persisted, so a track too large to draw fails cleanly.
		if tiles, err = computeTouchedTiles(points, FogZoom); err != nil {
			return Result{}, nil, err
		}
		if pp, err = prepareTrack(ctx, pool, points, nil); err != nil {
			return Result{}, nil, err
		}
		startedAt = points[0].Time
	}
	m := pp.m

	// Saved under the Private locations' lock, after checking they are still the ones the track
	// was clipped with: a change made since might not have found this track (LockZones).
	tx, err := pool.Begin(ctx)
	if err != nil {
		return Result{}, nil, fmt.Errorf("ingest: persist activity: %w", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck // no-op once committed
	if err := LockZones(ctx, tx, job.UserID); err != nil {
		return Result{}, nil, fmt.Errorf("ingest: lock Private locations: %w", err)
	}
	current, err := LoadZones(ctx, tx, job.UserID)
	if err != nil {
		return Result{}, nil, fmt.Errorf("ingest: reread Private locations: %w", err)
	}
	if !slices.Equal(current, zones) {
		return Result{}, current, errZonesChanged
	}
	// ingest_complete stays false until every step after this insert has run (the end of
	// this function): a hidden track has none, so it is complete as inserted.
	// timezone is the zone of the first recorded point, before Private locations clip it, so
	// a track hidden by them still shows its times where it was recorded (§4.30).
	var trackID string
	var inserted, complete bool
	err = tx.QueryRow(ctx, `
		WITH ins AS (
			INSERT INTO tracks (
				user_id, source, source_detail, external_id,
				track_type, distance_meters, duration_seconds, moving_seconds,
				elevation_gain_m, started_at,
				trajectory, raw_payload_key, name, description, ingest_complete,
				timezone, recorded_started_at, recorded_ended_at, raw_bytes,
				editable_times
			) VALUES (
				$1, $2, $3, $4,
				$5, $6, $7, $8,
				$9, $10,
				`+trajectorySQL("$11", "$12", "$13")+`,
				$14, NULLIF($15, ''), NULLIF($16, ''), $17,
				`+geo.TimezoneAtSQL("$18::float8", "$19::float8", "$1")+`,
				$20, $21, NULLIF($22::bigint, 0),
				$23
			)
			ON CONFLICT (user_id, source, external_id) WHERE external_id IS NOT NULL DO NOTHING
			RETURNING id
		)
		SELECT id, true, $17 FROM ins
		UNION ALL
		SELECT id, false, ingest_complete FROM tracks
		WHERE user_id = $1 AND source = $2 AND external_id = $4
		  AND NOT EXISTS (SELECT 1 FROM ins)
		LIMIT 1
	`,
		job.UserID, job.Source, job.SourceDetail, job.ExternalID,
		act.TrackType, m.distanceM, m.durationS, m.movingS,
		m.elevationGainM, startedAt,
		pp.simpLons, pp.simpLats, pp.simpTs,
		job.RawPayloadKey, act.Name, act.Description, hidden,
		act.Points[0].Lon, act.Points[0].Lat,
		recStart, recEnd, job.RawBytes,
		EditableTimestamps(points) == nil,
	).Scan(&trackID, &inserted, &complete)
	if err != nil {
		return Result{}, nil, fmt.Errorf("ingest: persist activity: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return Result{}, nil, fmt.Errorf("ingest: persist activity: %w", err)
	}

	if !inserted && complete {
		// Idempotency requirement: a duplicate that reached persist is a no-op, not an
		// error. Fog is skipped too: nothing new happened, so no tile needs marking dirty
		// again.
		return Result{TrackID: trackID, Persisted: false}, nil, nil
	}
	// Otherwise this is a new row, or one an earlier run of this ingest inserted and then
	// didn't finish (cut off, or failed partway): every step below is safe to run again.
	if hidden {
		// No masks, tiles or regions: there is nothing visible to derive them from.
		return Result{TrackID: trackID, Persisted: true}, nil, nil
	}

	// §4.1 step 4: render this track's own Fog masks and mark every z14 tile it
	// touches dirty, both from `points` (pre-simplification), not the simplified trajectory
	// just persisted — a straight line between two of Douglas-Peucker's surviving vertices
	// can cut across tiles the real GPS path never entered, which would render/reveal tiles
	// the user never actually visited. Rendering first, dirty-marking second: dirty is what
	// tells `render_fog` this tile's aggregate needs recompositing, so the mask it would
	// composite in should already exist by the time that runs.
	if err := fog.RenderTrackMasks(ctx, pool, trackID, points, tiles); err != nil {
		return Result{}, nil, fmt.Errorf("ingest: render activity masks: %w", err)
	}

	if err := MarkFogTilesDirty(ctx, pool, job.UserID, tiles); err != nil {
		return Result{}, nil, fmt.Errorf("ingest: mark fog tiles dirty: %w", err)
	}

	// Country/Region-tier unlocking (§4.2.4) — independent of the Fog raster pyramid
	// above, so it runs alongside it rather than inside fog's own dirty/render pipeline: there
	// is nothing here to mark dirty or recomposite, matching against track_id is enough.
	if err := geo.MatchTrack(ctx, pool, trackID); err != nil {
		return Result{}, nil, fmt.Errorf("ingest: match admin boundaries: %w", err)
	}

	if err := EnqueueRenderFog(ctx, pool, job.UserID); err != nil {
		return Result{}, nil, fmt.Errorf("ingest: enqueue render_fog: %w", err)
	}
	if _, err := pool.Exec(ctx, `UPDATE tracks SET ingest_complete = true WHERE id = $1`, trackID); err != nil {
		return Result{}, nil, fmt.Errorf("ingest: mark complete: %w", err)
	}

	return Result{TrackID: trackID, Persisted: true}, nil, nil
}

// loadClippedPoints is §4.1 steps 2–3: fetch the raw payload, parse it, and clip it against
// the account's Private locations, read now rather than when the job was enqueued. Shared by
// Process and reprocessTrack (edit.go) — an edit replays the user's spec on top of exactly
// the points a fresh ingest would have kept, never on hidden ones.
//
// The returned points are nil when the whole track lies inside Private locations; act still
// carries the parsed metadata (type, name, start time) the caller persists either way. The
// zones clipped with are returned too, for a caller that applies a route edit and has to clip
// its result again (RouteEdit.ApplyClipped).
func loadClippedPoints(ctx context.Context, pool *pgxpool.Pool, store *storage.Store, userID, sourceDetail, rawKey string) (parse.Track, []parse.Point, []Zone, error) {
	act, err := loadRecorded(ctx, store, sourceDetail, rawKey, 0)
	if err != nil {
		return parse.Track{}, nil, nil, err
	}

	// Continuous across the antimeridian from here on: every reader of these points, and the
	// trajectory built from them, sees a crossing as a short step.
	act.Points = unwrapLons(act.Points)

	zones, err := LoadZones(ctx, pool, userID)
	if err != nil {
		return parse.Track{}, nil, nil, fmt.Errorf("ingest: load private locations: %w", err)
	}
	return act, ClipEnds(act.Points, zones), zones, nil
}

// loadRecorded fetches and parses the raw payload, keeping the points every reader can use:
// the whole recording, before Private locations.
func loadRecorded(ctx context.Context, store *storage.Store, sourceDetail, rawKey string, maxPoints int) (parse.Track, error) {
	obj, err := store.Get(ctx, rawKey)
	if err != nil {
		return parse.Track{}, fmt.Errorf("ingest: fetch raw payload: %w", err)
	}
	defer obj.Close()

	// The store fetches lazily, so its own failure surfaces inside the parser; that one isn't
	// the file's fault, and the worker retries it.
	src := &objectReader{r: obj}
	act, err := parse.ByExtensionUpTo(sourceDetail, src, maxPoints)
	if err != nil {
		if src.err != nil {
			return parse.Track{}, fmt.Errorf("ingest: read raw payload: %w", src.err)
		}
		return parse.Track{}, parseError{err}
	}
	if act.Points, err = keepTimed(keepValid(act.Points)); err != nil {
		return parse.Track{}, err
	}
	if len(act.Points) < 2 {
		return parse.Track{}, fmt.Errorf("ingest: %w (%d)", errTooFewPoints, len(act.Points))
	}
	return act, nil
}

// keepValid drops the points no map can place — a NaN or infinite coordinate, a latitude at or
// past a pole, which Web Mercator puts at infinity, a longitude past the antimeridian — and an
// elevation that isn't finite. No
// parser checks ranges (a GPX attribute reads "Inf" as readily as a number, and a phone sync
// sends whatever it sends), and one such point anywhere breaks everything downstream: the
// tracks tile query's ST_Transform fails for every tile its bounding box covers, mask
// rasterizing walks a line out to the edge of the world, and an infinite elevation gain makes
// every stats response unencodable as JSON. As a first or last point it would also sit
// outside every Private location, so ClipEnds would clip nothing.
func keepValid(points []parse.Point) []parse.Point {
	valid := points[:0:0]
	for _, p := range points {
		if !(p.Lat > -90 && p.Lat < 90 && p.Lon >= -180 && p.Lon <= 180) { // false for NaN too
			continue
		}
		if p.Elevation != nil && (math.IsNaN(float64(*p.Elevation)) || math.IsInf(float64(*p.Elevation), 0)) {
			p.Elevation = nil
		}
		valid = append(valid, p)
	}
	return valid
}

// errNoTimestamps fails a file whose points carry no time at all — a planned route exported
// as GPX, typically. Every parser leaves a missing time as the zero time.Time, so such a
// track would otherwise be persisted as starting on 0001-01-01, with no duration, and be
// unreachable through the date range the whole map is filtered by.
var errNoTimestamps = errors.New("the file has no timestamps — a planned route, not a recorded activity")

// keepTimed drops the points with no timestamp, and fails when none has one. A few untimed
// points among timed ones (a stray waypoint) are dropped rather than failing the file; kept,
// each would read as a jump back to year 1 in the duration and pace arithmetic.
func keepTimed(points []parse.Point) ([]parse.Point, error) {
	timed := points[:0:0]
	for _, p := range points {
		if !p.Time.IsZero() {
			timed = append(timed, p)
		}
	}
	if len(timed) == 0 && len(points) > 0 {
		return nil, errNoTimestamps
	}
	return timed, nil
}

// trajectorySQL builds the display LineStringM from three parallel lon/lat/epoch-seconds
// array parameters, or NULL when they hold fewer than two points — a track entirely
// inside Private locations (§3.3 allows a null trajectory, and every reader already copes).
func trajectorySQL(lons, lats, ts string) string {
	return `CASE WHEN cardinality(` + lons + `::float8[]) >= 2 THEN ST_SetSRID(
					ST_MakeLine(ARRAY(
						SELECT ST_MakePointM(lon, lat, t)
						FROM unnest(` + lons + `::float8[], ` + lats + `::float8[], ` + ts + `::float8[]) AS pt(lon, lat, t)
					)),
					4326
				) END`
}

// preparedTrack is everything §4.1 steps 5–6 persist, derived from the final point list.
type preparedTrack struct {
	m                          metrics
	simpLons, simpLats, simpTs []float64
}

func prepareTrack(ctx context.Context, pool *pgxpool.Pool, points []parse.Point, edit *RouteEdit) (preparedTrack, error) {
	pp := preparedTrack{m: computeMetrics(points, edit)}

	lons := make([]float64, len(points))
	lats := make([]float64, len(points))
	ts := make([]float64, len(points))
	for i, p := range points {
		lons[i] = p.Lon
		lats[i] = p.Lat
		ts[i] = float64(p.Time.Unix())
	}

	// §4.1 step 5: simplify for display. Two round trips, not one — see simplify.go for
	// why ST_SimplifyPreserveTopology can't just be called inline on the LineStringM.
	var err error
	pp.simpLons, pp.simpLats, err = simplifyXY(ctx, pool, lons, lats, simplifyToleranceDeg)
	if err != nil {
		return preparedTrack{}, err
	}
	pp.simpTs = matchSimplifiedTimes(lons, lats, ts, pp.simpLons, pp.simpLats)
	return pp, nil
}

// mergeTiles unions two tile lists, dropping duplicates — MarkFogTilesDirty is an upsert, so
// a repeat is harmless, but the dirty set is also what bounds the rebuild's cost.
func mergeTiles(a, b [][2]int) [][2]int {
	if len(b) == 0 {
		return a
	}
	seen := make(map[[2]int]struct{}, len(a)+len(b))
	out := make([][2]int, 0, len(a)+len(b))
	for _, list := range [][][2]int{a, b} {
		for _, t := range list {
			if _, ok := seen[t]; ok {
				continue
			}
			seen[t] = struct{}{}
			out = append(out, t)
		}
	}
	return out
}

// FogZoom is exported alongside MarkFogTilesDirty/EnqueueRenderFog — a caller re-triggering a
// render (handleDeleteTrack) needs the same zoom level track_tile_masks/fog_tiles are
// actually keyed at to query the right rows.
const FogZoom = 14

// computeTouchedTiles walks the raw, pre-simplification trajectory and returns every z14
// tile it passes through — including tiles between consecutive points, not just the tiles
// containing a point (see tilemath.SegmentTilesBuffered), and including any tile a point or
// segment never enters but sits close enough to (within fog.TileMarginPx) that the rendered
// stroke's own drawn width still reaches into. Shared by RenderTrackMasks (which tiles to
// render a mask for) and MarkFogTilesDirty (which tiles to flag for aggregate rebuild) — the
// two need to agree exactly, or a rendered mask could sit in a tile never marked dirty (never
// composited in) or vice versa.
//
// It fails with errTooManyTiles past maxTrackTiles, checked as it goes: each tile is a
// mask rendered and stored, and a track zigzagging between far-apart points (a crafted file,
// or a corrupt one) could otherwise reach millions of them, held in memory here and then
// rendered one by one on the single worker.
func computeTouchedTiles(points []parse.Point, zoom int) ([][2]int, error) {
	seen := map[[2]int]struct{}{}
	add := func(tiles [][2]int) error {
		for _, t := range tiles {
			seen[t] = struct{}{}
		}
		if len(seen) > maxTrackTiles {
			return errTooManyTiles
		}
		return nil
	}

	if len(points) == 1 {
		if err := add(tilemath.SegmentTilesBuffered(points[0].Lon, points[0].Lat, points[0].Lon, points[0].Lat, zoom, fog.TileMarginPx, fog.TileSize)); err != nil {
			return nil, err
		}
	}
	for i := 1; i < len(points); i++ {
		if err := add(tilemath.SegmentTilesBuffered(points[i-1].Lon, points[i-1].Lat, points[i].Lon, points[i].Lat, zoom, fog.TileMarginPx, fog.TileSize)); err != nil {
			return nil, err
		}
	}

	out := make([][2]int, 0, len(seen))
	for t := range seen {
		out = append(out, t)
	}
	return out, nil
}

// maxTrackTiles bounds how many z14 tiles (about 2.4 km across) one track may touch. A
// 10,000 km road trip, buffered on both sides, is around 12,000.
const maxTrackTiles = 20000

// errTooManyTiles fails a track that covers more ground than maxTrackTiles allows.
var errTooManyTiles = fmt.Errorf("the track touches more than %d map tiles", maxTrackTiles)

// MarkFogTilesDirty upserts a fog_tiles row (dirty = true) for every given z14 tile —
// computeTouchedTiles' result for a fresh ingest, a deleted track's own already-rendered
// tiles (`internal/httpapi`'s handleDeleteTrack, which has no raw points to recompute
// touched tiles from — it reads them back out of track_tile_masks before the cascade
// removes that row, via TrackTiles below). Exported for those callers;
// the upsert itself doesn't care which triggered it.
func MarkFogTilesDirty(ctx context.Context, pool *pgxpool.Pool, userID string, tiles [][2]int) error {
	if len(tiles) == 0 {
		return nil
	}

	xs := make([]int32, 0, len(tiles))
	ys := make([]int32, 0, len(tiles))
	for _, t := range tiles {
		xs = append(xs, int32(t[0]))
		ys = append(ys, int32(t[1]))
	}

	_, err := pool.Exec(ctx, `
		INSERT INTO fog_tiles (user_id, zoom, tile_x, tile_y, dirty)
		SELECT $1, $2, x, y, true
		FROM unnest($3::int[], $4::int[]) AS t(x, y)
		ORDER BY x, y
		ON CONFLICT (user_id, zoom, tile_x, tile_y) DO UPDATE SET dirty = true, dirty_gen = fog_tiles.dirty_gen + 1
	`, userID, FogZoom, xs, ys)
	return err
}

// TrackTiles reads back the z14 tiles one track's own crisp masks cover —
// track_tile_masks' primary key leads with track_id, so this is an index-only lookup.
func TrackTiles(ctx context.Context, pool *pgxpool.Pool, trackID string) ([][2]int, error) {
	rows, err := pool.Query(ctx,
		`SELECT DISTINCT tile_x, tile_y FROM track_tile_masks WHERE track_id = $1 AND zoom = $2`,
		trackID, FogZoom,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var tiles [][2]int
	for rows.Next() {
		var x, y int
		if err := rows.Scan(&x, &y); err != nil {
			return nil, err
		}
		tiles = append(tiles, [2]int{x, y})
	}
	return tiles, rows.Err()
}

// RenderFogJob is `render_fog`'s payload — just enough to say whose tiles to render, since
// which tiles is the dirty flag's job, not this payload's.
type RenderFogJob struct {
	UserID string `json:"user_id"`
}

// EnqueueRenderFog is one job per user, not one per tile or per ingest — the job's own
// query (`SELECT ... FROM fog_tiles WHERE user_id = $1 AND dirty`) is what actually decides
// what to render, so several ingests (or a delete, or both) landing before the worker gets to
// them coalesce into one render pass instead of redoing the same tiles repeatedly. Exported
// for handleDeleteTrack, which needs the exact same "something changed, re-render this
// user's dirty tiles" trigger ingest already has.
//
// The coalescing is this INSERT's: it adds no job while the user already has a render_fog
// waiting unclaimed, since that one reads the dirty flags only once claimed, after every
// caller has committed its marks (they all mark before enqueueing). A claimed one may have
// read them already, so it doesn't count, and nor does one waiting out a retry delay
// (run_after ahead), which would hold this change's render back until it ran. Without this, a
// 584-track import queued 584 renders of ~40 s each, every one after the first redrawing
// nothing new.
func EnqueueRenderFog(ctx context.Context, pool *pgxpool.Pool, userID string) error {
	payload, err := json.Marshal(RenderFogJob{UserID: userID})
	if err != nil {
		return err
	}
	_, err = pool.Exec(ctx, `
		INSERT INTO jobs (kind, user_id, payload)
		SELECT 'render_fog', $1, $2
		WHERE NOT EXISTS (
			SELECT 1 FROM jobs
			WHERE kind = 'render_fog' AND user_id = $1 AND state = 'pending' AND locked_at IS NULL
			  AND run_after <= NOW()
		)`,
		userID, payload,
	)
	return err
}

type metrics struct {
	distanceM      float64
	durationS      int
	movingS        int
	elevationGainM float64
}

// movingSpeedThresholdMps is the speed below which a segment counts as stopped, not moving,
// for movingS below. ~1.8 km/h: fast enough to filter GPS jitter while genuinely stationary
// (a few meters of drift over several seconds), slow enough not to exclude real, deliberate
// slow walking.
const movingSpeedThresholdMps = 0.5

// computeMetrics sums points after edit. Elapsed time alone spans a Cut's join (JoinsCut).
func computeMetrics(points []parse.Point, edit *RouteEdit) metrics {
	var m metrics
	// Summed in seconds as fractions and rounded once: rounding each segment down dropped
	// every sub-second gap of a millisecond-stamped recording (the phone's) to nothing.
	var movingS float64
	for i := 1; i < len(points); i++ {
		if edit.JoinsCut(points[i-1].Time.UnixMilli(), points[i].Time.UnixMilli()) {
			continue
		}
		segM := HaversineM(points[i-1].Lat, points[i-1].Lon, points[i].Lat, points[i].Lon)
		m.distanceM += segM
		if points[i-1].Elevation != nil && points[i].Elevation != nil {
			d := float64(*points[i].Elevation - *points[i-1].Elevation)
			if d > 0 {
				m.elevationGainM += d
			}
		}
		dt := points[i].Time.Sub(points[i-1].Time).Seconds()
		if dt > 0 && segM/dt >= movingSpeedThresholdMps {
			movingS += dt
		}
	}
	m.durationS = int(points[len(points)-1].Time.Sub(points[0].Time).Seconds())
	// Rounded where elapsed time is cut, so never past it: 10.6 s of moving in 10.6 s is 10.
	m.movingS = min(int(math.Round(movingS)), m.durationS)
	return m
}
