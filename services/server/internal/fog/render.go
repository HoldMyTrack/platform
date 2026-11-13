package fog

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"image"
	"image/draw"
	"image/png"
	"io"
	"log/slog"
	"math"
	"sync/atomic"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/HoldMyTrack/platform/services/server/internal/parallel"
	"github.com/HoldMyTrack/platform/services/server/internal/parse"
	"github.com/HoldMyTrack/platform/services/server/internal/storage"
	"github.com/HoldMyTrack/platform/services/server/internal/tilemath"
)

// renderParallelism bounds how many tiles (or masks) a render works on at once. The work is
// mostly waiting — a z14 tile is a query for its masks and its PUT, a pyramid tile a query,
// its children's GETs side by side and its PUT, each PUT or GET a
// round trip to R2 — so running tiles one after another left a render at about 1.3 tiles a
// second on the production droplet (the 2026-10-08 load test), almost none of it CPU. Bounded rather
// than unbounded so memory stays predictable (IMPLEMENTATION.md §5.2): each in-flight tile
// holds a few decoded masks.
const renderParallelism = 16

// RenderUser is the `render_fog` job body: re-render every tile currently marked dirty for
// this user, z14 first and then each pyramid level up to z0. Idempotent and complete per
// tile, not incremental — each render gathers *every* activity intersecting a tile, not just
// whichever one triggered the dirty flag, because a tile's mask has to represent the user's
// entire history through it every time, not just the newest activity.
//
// Rendering a tile marks its parent dirty, so the pyramid's pending work is in the database,
// not in memory: a pass cut off partway (a storage error, a deploy) leaves the parents of
// what it rendered dirty, and the next pass finishes them rather than leaving z13 and above
// stale until something else happens to touch the same tiles.
//
// A pass that stored anything ends by bumping map_version (BumpMapVersion), a failed one
// too — its tiles are already overwritten — so a client never keeps a cached tile past it.
//
// One account's passes never overlap (lockRenders): a `render_fog` job runs in a lane of its
// own (internal/worker), beside the account's edit or reprivacy job that renders inline.
func RenderUser(ctx context.Context, pool *pgxpool.Pool, store *storage.Store, userID string) (err error) {
	unlock, err := lockRenders(ctx, pool, userID)
	if err != nil {
		return fmt.Errorf("fog: lock renders: %w", err)
	}
	defer unlock()

	rendered := false
	defer func() {
		if !rendered {
			return
		}
		// On a context a shutdown hasn't cancelled: the tiles stored before it are new either way.
		if berr := BumpMapVersion(context.WithoutCancel(ctx), pool, userID); berr != nil && err == nil {
			err = fmt.Errorf("fog: bump map version: %w", berr)
		}
	}()

	// Masks a z14 tile was composited without (renderAndStoreTile): logged once per pass, so
	// coverage missing after a restore isn't silent.
	var skipped atomic.Int64
	defer func() {
		if n := skipped.Load(); n > 0 {
			slog.Warn("fog: render skipped unreadable activity masks", "user", userID, "masks", n)
		}
	}()

	// Above z14 the client overzooms the z14 raster directly (§4.2) — no pyramid needed there.
	for z := Zoom; z >= 0; z-- {
		dirty, err := dirtyTiles(ctx, pool, userID, z)
		if err != nil {
			return fmt.Errorf("fog: list dirty z%d tiles: %w", z, err)
		}
		if len(dirty) > 0 {
			rendered = true
		}
		// A level's tiles are independent of each other, so they render side by side; the
		// next level up waits for all of them, since its tiles are built from these.
		err = parallel.ForEach(ctx, len(dirty), renderParallelism, func(ctx context.Context, i int) error {
			t := dirty[i]
			var err error
			if z == Zoom {
				err = renderAndStoreTile(ctx, pool, store, userID, z, t[0], t[1], &skipped)
			} else {
				err = renderPyramidLevel(ctx, pool, store, userID, z, t[0], t[1])
			}
			if err != nil {
				return fmt.Errorf("fog: render z%d/%d/%d: %w", z, t[0], t[1], err)
			}
			return nil
		})
		if err != nil {
			return err
		}
	}
	return nil
}

// renderLockClass is the first key of the advisory lock lockRenders takes, so it can't meet
// any other advisory lock this database might take with the same user hash.
const renderLockClass = 0x666f67 // "fog"

// lockRenders waits for, then holds, a session advisory lock on one account's renders until
// the returned unlock is called. Two passes side by side would race over the same tile: the
// one that read the masks first can store its tile after the other's fresher one, and the
// fresher pass has already cleared the dirty flag (upsertTileRendered), so nothing would ever
// redraw it. A session lock rather than a transaction's, so a pass minutes long doesn't keep a
// transaction open; it holds one pool connection for as long.
func lockRenders(ctx context.Context, pool *pgxpool.Pool, userID string) (unlock func(), err error) {
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return nil, err
	}
	if _, err := conn.Exec(ctx, `SELECT pg_advisory_lock($1, hashtext($2))`, renderLockClass, userID); err != nil {
		// Cancelled mid-wait, the session may or may not hold the lock: drop it rather than
		// hand it back to the pool.
		_ = conn.Conn().Close(context.WithoutCancel(ctx))
		conn.Release()
		return nil, err
	}
	return func() {
		if _, err := conn.Exec(context.WithoutCancel(ctx), `SELECT pg_advisory_unlock($1, hashtext($2))`, renderLockClass, userID); err != nil {
			// Closing the session is what releases the lock now.
			_ = conn.Conn().Close(context.WithoutCancel(ctx))
		}
		conn.Release()
	}, nil
}

// Private locations are never re-applied here: RenderActivityMasks renders from points
// already clipped at ingest, and renderAndStoreTile composites those masks rather than
// re-parsing raw payloads. A location change goes through the `reprivacy` job instead, which
// re-renders each affected activity's own masks from freshly clipped points (internal/ingest's
// ProcessReprivacy) before this recomposites.

func dirtyTiles(ctx context.Context, pool *pgxpool.Pool, userID string, zoom int) ([][2]int, error) {
	rows, err := pool.Query(ctx,
		`SELECT tile_x, tile_y FROM fog_tiles WHERE user_id = $1 AND zoom = $2 AND dirty`,
		userID, zoom,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out [][2]int
	for rows.Next() {
		var x, y int
		if err := rows.Scan(&x, &y); err != nil {
			return nil, err
		}
		out = append(out, [2]int{x, y})
	}
	return out, rows.Err()
}

// renderAndStoreTile is one z14 tile, fully re-rendered from the per-activity masks already
// on file for it — no raw-payload re-fetch/re-parse here any more (see RenderActivityMasks,
// which is what actually does that, once per activity, at ingest time). This is also more
// precise than the old bbox-intersection query it replaces: activity_tile_masks only ever
// contains tiles the *raw* trajectory actually passed through, not an approximation from the
// simplified trajectory's bounding box.
//
// The masks' bytes come in the same query, from activity_tile_mask_data (IMPLEMENTATION.md §3.11), so a tile
// costs one SQL read rather than a round trip to object storage per activity through it. A
// mask that can't be read — no bytes (a restore leaves them out until `rerender-coverage
// --masks` redraws them), or bytes that don't decode — is left out of the tile and counted in
// skipped, rather than failing it: every other activity through the tile is still real
// coverage, the same "one bad file doesn't abort the batch" principle §5.1 applies to bulk
// ingest.
//
// A Pending activity (edit_pending, §4.7.7) is left out: its masks are the pre-reprocess ones,
// or mid-rewrite. The reprocess marks its tiles dirty when it goes Pending and renders them
// again after clearing the flag, so it drops out of the tile for the duration.
func renderAndStoreTile(ctx context.Context, pool *pgxpool.Pool, store *storage.Store, userID string, zoom, x, y int, skipped *atomic.Int64) error {
	gen, err := tileDirtyGen(ctx, pool, userID, zoom, x, y)
	if err != nil {
		return err
	}
	rows, err := pool.Query(ctx, `
		SELECT d.png
		FROM activity_tile_masks m
		JOIN activities a ON a.id = m.activity_id
		LEFT JOIN activity_tile_mask_data d USING (activity_id, zoom, tile_x, tile_y)
		WHERE a.user_id = $1 AND NOT a.edit_pending
		  AND m.zoom = $2 AND m.tile_x = $3 AND m.tile_y = $4
	`, userID, zoom, x, y)
	if err != nil {
		return fmt.Errorf("query activity masks: %w", err)
	}
	var masks []*image.Gray
	for rows.Next() {
		var b []byte
		if err := rows.Scan(&b); err != nil {
			rows.Close()
			return fmt.Errorf("scan activity mask: %w", err)
		}
		if b == nil {
			skipped.Add(1)
			continue
		}
		mask, err := decodeGray(bytes.NewReader(b))
		if err != nil {
			skipped.Add(1)
			continue
		}
		masks = append(masks, mask)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}

	size, err := storeFogTile(ctx, store, userID, zoom, x, y, compositeFogMask(masks))
	if err != nil {
		return err
	}
	return upsertTileRendered(ctx, pool, userID, zoom, x, y, gen, fogObjectKey(userID, zoom, x, y), size)
}

// errTileSize is decodeGray's refusal of a PNG that isn't TileSize square.
var errTileSize = errors.New("fog: stored tile is not TileSize")

// decodeGray decodes a PNG this package wrote. png.Decode hands back *image.Gray for those
// grayscale PNGs, but convert explicitly rather than assume the concrete type.
//
// One of another size is refused: every raster here indexes a TileSize square, so a tile or
// mask drawn before TileSize last changed (IMPLEMENTATION.md §4.2) — until `rerender-coverage --masks` redraws
// it — would read past a smaller one's end (downsampleQuadrants) or land squashed in a corner of
// the tile (compositeFogMask) instead. A child tile refused fails its render; an activity's
// mask refused is skipped and counted, as an unreadable one is.
func decodeGray(r io.Reader) (*image.Gray, error) {
	img, err := png.Decode(r)
	if err != nil {
		return nil, err
	}
	if b := img.Bounds(); b.Dx() != TileSize || b.Dy() != TileSize {
		return nil, fmt.Errorf("%w: %dx%d, want %d (rerender-coverage --masks redraws it)", errTileSize, b.Dx(), b.Dy(), TileSize)
	}
	if gray, ok := img.(*image.Gray); ok {
		return gray, nil
	}
	b := img.Bounds()
	gray := image.NewGray(b)
	draw.Draw(gray, b, img, b.Min, draw.Src)
	return gray, nil
}

// RenderActivityMasks renders exactly one activity's own crisp (unblurred) stroke mask for
// each of its already-computed touched z14 tiles (internal/ingest's computeTouchedTiles), and
// upserts one activity_tile_masks row per tile with its PNG in activity_tile_mask_data, both
// in one transaction (IMPLEMENTATION.md §3.11). Idempotent: safe to re-run for the same activity (a
// redelivered ingest job).
//
// Called from ingest.Process with the points already in memory (pre-simplification, already
// privacy-clipped) — unlike the old per-tile re-render this replaces, this never reads raw
// payloads back from object storage for the activity that triggered it. Ingest-time
// rendering cost is now proportional to just this one activity's own tiles, independent of
// how many *other* activities already touch them — the old design re-parsed every one of
// them on every tile they shared.
func RenderActivityMasks(ctx context.Context, pool *pgxpool.Pool, activityID string, points []parse.Point, tiles [][2]int) error {
	if len(tiles) == 0 {
		return nil
	}

	xs := make([]int32, len(tiles))
	ys := make([]int32, len(tiles))
	pngs := make([][]byte, len(tiles))
	// Rendered side by side: a long track crosses hundreds of tiles.
	if err := parallel.ForEach(ctx, len(tiles), renderParallelism, func(ctx context.Context, i int) error {
		x, y := tiles[i][0], tiles[i][1]
		b, err := encodeTilePNG(renderActivityMask(projectToTile(points, x, y, Zoom)...))
		if err != nil {
			return fmt.Errorf("activity mask z%d/%d/%d: %w", Zoom, x, y, err)
		}
		xs[i], ys[i], pngs[i] = int32(x), int32(y), b
		return nil
	}); err != nil {
		return err
	}

	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck // no-op if already committed
	if _, err := tx.Exec(ctx, `
		INSERT INTO activity_tile_masks (activity_id, zoom, tile_x, tile_y, rendered_at)
		SELECT $1, $2, x, y, NOW()
		FROM unnest($3::int[], $4::int[]) AS t(x, y)
		ON CONFLICT (activity_id, zoom, tile_x, tile_y)
		DO UPDATE SET rendered_at = NOW()
	`, activityID, Zoom, xs, ys); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO activity_tile_mask_data (activity_id, zoom, tile_x, tile_y, png)
		SELECT $1, $2, x, y, png
		FROM unnest($3::int[], $4::int[], $5::bytea[]) AS t(x, y, png)
		ON CONFLICT (activity_id, zoom, tile_x, tile_y)
		DO UPDATE SET png = EXCLUDED.png
	`, activityID, Zoom, xs, ys, pngs); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// RemoveActivityMasks deletes one activity's masks for the given tiles — the tiles an edited
// track (internal/ingest's ProcessTrackEdit) no longer touches. Their bytes go with them (the
// cascade from activity_tile_masks to activity_tile_mask_data); a render_fog pass running
// alongside simply composites without them.
func RemoveActivityMasks(ctx context.Context, pool *pgxpool.Pool, activityID string, tiles [][2]int) error {
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
		DELETE FROM activity_tile_masks m
		USING unnest($3::int[], $4::int[]) AS t(x, y)
		WHERE m.activity_id = $1 AND m.zoom = $2 AND m.tile_x = t.x AND m.tile_y = t.y
	`, activityID, Zoom, xs, ys)
	return err
}

// projectToTile places points in the tile's own pixels, once for each copy of the world that
// reaches it: a track continuing past ±180 (ingest's unwrapLons) lies partly in the next copy
// over, whose pixels are a world's width away, so a tile on the other side of the
// antimeridian is drawn from the track shifted by that width. A copy that doesn't come within
// TileMarginPx of the tile is left out: the rasterizer still pays for a path a world away
// from its canvas, over a minute at z14.
func projectToTile(points []parse.Point, tileX, tileY, zoom int) [][]pixelPoint {
	world := math.Pow(2, float64(zoom)) * TileSize
	originX := float64(tileX) * TileSize
	originY := float64(tileY) * TileSize
	base := make([]pixelPoint, len(points))
	minX, maxX := math.Inf(1), math.Inf(-1)
	for i, p := range points {
		wx, wy := tilemath.WorldPixel(p.Lon, p.Lat, zoom, TileSize)
		base[i] = pixelPoint{x: wx - originX, y: wy - originY}
		minX, maxX = math.Min(minX, base[i].x), math.Max(maxX, base[i].x)
	}
	var out [][]pixelPoint
	for _, shift := range []float64{0, -world, world} {
		if maxX+shift < -TileMarginPx || minX+shift > TileSize+TileMarginPx {
			continue
		}
		if shift == 0 {
			out = append(out, base)
			continue
		}
		shifted := make([]pixelPoint, len(base))
		for i, p := range base {
			shifted[i] = pixelPoint{x: p.x + shift, y: p.y}
		}
		out = append(out, shifted)
	}
	return out
}

// renderPyramidLevel builds one parent tile by downsampling its four children — each
// loaded from whatever is currently stored for it (or blank, if it has never been
// rendered), not just the children that happened to change this pass. A parent has to be a
// complete, correct downsample of its children's *current* state every time, the same
// completeness requirement renderAndStoreTile has at z14.
//
// The children's keys come in one query and their images are fetched side by side: one
// after another, a pyramid tile was about ten round trips to object storage.
func renderPyramidLevel(ctx context.Context, pool *pgxpool.Pool, store *storage.Store, userID string, zoom, x, y int) error {
	gen, err := tileDirtyGen(ctx, pool, userID, zoom, x, y)
	if err != nil {
		return err
	}
	children, err := loadChildren(ctx, pool, store, userID, zoom+1, x, y)
	if err != nil {
		return err
	}
	size, err := storeFogTile(ctx, store, userID, zoom, x, y, downsampleQuadrants(children))
	if err != nil {
		return err
	}
	return upsertTileRendered(ctx, pool, userID, zoom, x, y, gen, fogObjectKey(userID, zoom, x, y), size)
}

// loadChildren reads the four children at zoom of parent (px, py), in downsampleQuadrants'
// order (top left, top right, bottom left, bottom right). A child with no fog_tiles row, or not
// rendered yet, is blank — fully fogged, the correct stand-in for "nothing here", not an error,
// since a user's history need not touch every sibling tile.
func loadChildren(ctx context.Context, pool *pgxpool.Pool, store *storage.Store, userID string, zoom, px, py int) ([4]*image.Gray, error) {
	var out [4]*image.Gray
	for i := range out {
		out[i] = blankTile()
	}
	rows, err := pool.Query(ctx, `
		SELECT tile_x, tile_y, object_key FROM fog_tiles
		WHERE user_id = $1 AND zoom = $2 AND tile_x = ANY($3) AND tile_y = ANY($4)`,
		userID, zoom, []int32{int32(px * 2), int32(px*2 + 1)}, []int32{int32(py * 2), int32(py*2 + 1)})
	if err != nil {
		return out, err
	}
	var keys [4]string
	for rows.Next() {
		var cx, cy int
		var key *string
		if err := rows.Scan(&cx, &cy, &key); err != nil {
			rows.Close()
			return out, err
		}
		if key != nil {
			keys[(cx-px*2)+2*(cy-py*2)] = *key
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return out, err
	}
	err = parallel.ForEach(ctx, len(keys), len(keys), func(ctx context.Context, i int) error {
		if keys[i] == "" {
			return nil
		}
		obj, err := store.Get(ctx, keys[i])
		if err != nil {
			return err
		}
		defer obj.Close()
		img, err := decodeGray(obj)
		if err != nil {
			return err
		}
		out[i] = img
		return nil
	})
	return out, err
}

// storeFogTile stores one tile's Fog mask and returns its size, for fog_tiles' storage
// statistics (IMPLEMENTATION.md §4.32). Beside it, it removes the tile's Heatmap counts if the
// bucket still holds them, so a redrawn tile leaves no per-place counts behind. fog_tiles'
// heatmap columns are left unwritten: nothing reads them, and a binary that never names them
// keeps working while a migration drops them.
func storeFogTile(ctx context.Context, store *storage.Store, userID string, zoom, x, y int, mask *image.Gray) (int, error) {
	var size int
	err := parallel.ForEach(ctx, 2, 2, func(ctx context.Context, i int) error {
		if i == 0 {
			var err error
			size, err = storeTilePNG(ctx, store, fogObjectKey(userID, zoom, x, y), mask)
			return err
		}
		return store.Remove(ctx, heatmapObjectKey(userID, zoom, x, y))
	})
	return size, err
}

// storeTilePNG stores mask as a PNG at key and returns its size.
func storeTilePNG(ctx context.Context, store *storage.Store, key string, mask image.Image) (int, error) {
	b, err := encodeTilePNG(mask)
	if err != nil {
		return 0, err
	}
	return len(b), store.Put(ctx, key, bytes.NewReader(b), int64(len(b)))
}

func encodeTilePNG(mask image.Image) ([]byte, error) {
	var buf bytes.Buffer
	if err := png.Encode(&buf, mask); err != nil {
		return nil, fmt.Errorf("encode png: %w", err)
	}
	return buf.Bytes(), nil
}

func fogObjectKey(userID string, zoom, x, y int) string {
	return fmt.Sprintf("fog/%s/%d/%d/%d.png", userID, zoom, x, y)
}

// heatmapObjectKey is where a tile's Heatmap counts were stored, for storeFogTile to remove.
func heatmapObjectKey(userID string, zoom, x, y int) string {
	return fmt.Sprintf("heatmap/%s/%d/%d/%d.png", userID, zoom, x, y)
}

// tileDirtyGen is a tile's dirty_gen as a render starts, read before anything it draws from:
// upsertTileRendered clears dirty only if no one has marked the tile again since. 0 for a
// tile with no row yet.
func tileDirtyGen(ctx context.Context, pool *pgxpool.Pool, userID string, zoom, x, y int) (int64, error) {
	var gen int64
	err := pool.QueryRow(ctx,
		`SELECT dirty_gen FROM fog_tiles WHERE user_id = $1 AND zoom = $2 AND tile_x = $3 AND tile_y = $4`,
		userID, zoom, x, y,
	).Scan(&gen)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, nil
	}
	return gen, err
}

// upsertTileRendered records a fresh render, and marks the tile's parent dirty in the same
// transaction (RenderUser walks the pyramid off that flag). INSERT ... ON CONFLICT, not a plain
// UPDATE: a pyramid tile (z13..z0) may have no fog_tiles row yet the first time it's built.
//
// dirty clears only if dirty_gen is still gen, the value read before the render gathered its
// masks. A change that lands mid-render — an activity deleted while its old mask was being
// composited in — marks the tile again (bumping dirty_gen), and the tile stays dirty for the
// render the change enqueued, instead of keeping the deleted track until something else
// touches that tile.
func upsertTileRendered(ctx context.Context, pool *pgxpool.Pool, userID string, zoom, x, y int, gen int64, fogKey string, size int) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck // no-op once committed
	if _, err := tx.Exec(ctx, `
		INSERT INTO fog_tiles (user_id, zoom, tile_x, tile_y, object_key, bytes, dirty, rendered_at)
		VALUES ($1, $2, $3, $4, $5, $7, false, NOW())
		ON CONFLICT (user_id, zoom, tile_x, tile_y)
		DO UPDATE SET object_key = EXCLUDED.object_key, bytes = EXCLUDED.bytes,
			dirty = fog_tiles.dirty_gen <> $6, rendered_at = NOW()
	`, userID, zoom, x, y, fogKey, gen, size); err != nil {
		return err
	}
	if zoom > 0 {
		if _, err := tx.Exec(ctx, `
			INSERT INTO fog_tiles (user_id, zoom, tile_x, tile_y, dirty)
			VALUES ($1, $2, $3, $4, true)
			ON CONFLICT (user_id, zoom, tile_x, tile_y) DO UPDATE SET dirty = true, dirty_gen = fog_tiles.dirty_gen + 1
		`, userID, zoom-1, x/2, y/2); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}
