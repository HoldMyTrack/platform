package worker

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/HoldMyTrack/platform/services/server/internal/parallel"
	"github.com/HoldMyTrack/platform/services/server/internal/storage"
)

// purgeParallelism is how many of an account's storage prefixes purgeAccount removes at once.
const purgeParallelism = 16

// purgeRetryDelay is how long an account whose purge failed waits before the next try, so that
// accounts failing every time don't fill each batch and keep later ones from being purged.
const purgeRetryDelay = 10 * time.Minute

// purgeHeld is the accounts waiting out purgeRetryDelay, in this worker's memory: a restart
// lets them all straight back in, which costs a try each.
var purgeHeld = heldAccounts{until: map[string]time.Time{}}

type heldAccounts struct {
	mu    sync.Mutex
	until map[string]time.Time
}

func (h *heldAccounts) hold(id string, until time.Time) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.until[id] = until
}

func (h *heldAccounts) release(id string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.until, id)
}

// ids is the accounts still held at now, forgetting the ones whose wait is over.
func (h *heldAccounts) ids(now time.Time) []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	ids := []string{}
	for id, until := range h.until {
		if now.Before(until) {
			ids = append(ids, id)
		} else {
			delete(h.until, id)
		}
	}
	return ids
}

// accountPurgeBatchSize bounds one sweep; the next tick takes the rest.
const accountPurgeBatchSize = 20

// purgeDeletedAccounts finishes what httpapi's closeAccount started (SPEC FR-1.12): for every
// account with deleted_at set, it removes the account's stored objects, then its users row,
// whose cascade takes every other row it owns — tracks, photos, Trips, Private
// locations, captures, imports, jobs.
//
// An account with a job still running (claimed within claimLease) waits for the next tick:
// the job could write a raw file, a tile or a mask after the sweep had already listed them.
// Its pending jobs are dropped first, so nothing new starts for it in the meantime.
//
// Objects first, row second: a removal that fails leaves the account for the next sweep, since
// once the row is gone nothing names what was left behind, the account's unclipped originals
// among it. The account is closed from the start (closeAccount), so waiting costs only the
// storage. The track masks are keyed by track id, so those ids are read before the row
// goes.
//
// Photos are the exception, since a copied Trip's photo (IMPLEMENTATION.md §4.23) is another
// account's row over the same files: the account's photo files that another account's rows
// still use are kept, and the files of copies the account received go too when no other
// account's rows use them.
func purgeDeletedAccounts(ctx context.Context, pool *pgxpool.Pool, store *storage.Store, log *slog.Logger) error {
	rows, err := pool.Query(ctx, `
		SELECT id FROM users WHERE deleted_at IS NOT NULL AND NOT (id = ANY($2::uuid[]))
		ORDER BY deleted_at LIMIT $1
	`, accountPurgeBatchSize, purgeHeld.ids(time.Now()))
	if err != nil {
		return fmt.Errorf("account purge: query: %w", err)
	}
	var userIDs []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return fmt.Errorf("account purge: scan: %w", err)
		}
		userIDs = append(userIDs, id)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return fmt.Errorf("account purge: rows: %w", err)
	}

	for _, userID := range userIDs {
		if err := purgeAccount(ctx, pool, store, log, userID); err != nil {
			log.Error("account purge failed", "user_id", userID, "err", err)
			purgeHeld.hold(userID, time.Now().Add(purgeRetryDelay))
		} else {
			purgeHeld.release(userID)
		}
	}
	return nil
}

func purgeAccount(ctx context.Context, pool *pgxpool.Pool, store *storage.Store, log *slog.Logger, userID string) error {
	if _, err := pool.Exec(ctx, `
		DELETE FROM jobs WHERE user_id = $1 AND state = 'pending'
		  AND (locked_at IS NULL OR locked_at < NOW() - make_interval(secs => $2))
	`, userID, claimLease.Seconds()); err != nil {
		return fmt.Errorf("drop pending jobs: %w", err)
	}
	var running bool
	if err := pool.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM jobs WHERE user_id = $1 AND state = 'pending')`, userID,
	).Scan(&running); err != nil {
		return fmt.Errorf("running jobs: %w", err)
	}
	if running {
		log.Info("account purge: waiting for a running job", "user_id", userID)
		return nil
	}

	prefixes := []string{
		"raw/" + userID + "/", "fog/" + userID + "/", "exports/" + userID + "/",
	}
	// Side by side: each prefix is a listing and a bulk delete, round trips to object storage,
	// and a big account's fog/ holds thousands of tiles. Each runs to its end however the others
	// fare, so one failing prefix neither stops the rest nor hides their failures.
	var mu sync.Mutex
	var failed []error
	if err := parallel.ForEach(ctx, len(prefixes), purgeParallelism, func(ctx context.Context, i int) error {
		if err := store.RemoveByPrefix(ctx, prefixes[i]); err != nil {
			mu.Lock()
			failed = append(failed, fmt.Errorf("%s: %w", prefixes[i], err))
			mu.Unlock()
		}
		return nil
	}); err != nil {
		return fmt.Errorf("storage cleanup, left for the next sweep: %w", err)
	}
	if err := errors.Join(failed...); err != nil {
		return fmt.Errorf("storage cleanup, left for the next sweep: %w", err)
	}
	photoPrefix := "photos/" + userID + "/"
	rows, err := pool.Query(ctx, `
		SELECT DISTINCT image_key FROM activity_photos WHERE image_key LIKE $1 || '%' AND user_id <> $2`, photoPrefix, userID)
	if err != nil {
		return fmt.Errorf("shared photos: %w", err)
	}
	shared, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return fmt.Errorf("shared photos: %w", err)
	}
	keep := make(map[string]bool, 2*len(shared))
	for _, key := range shared {
		keep[key], keep[key+"-thumb"] = true, true
	}
	if err := store.RemoveByPrefixExcept(ctx, photoPrefix, func(key string) bool { return keep[key] }); err != nil {
		return fmt.Errorf("storage cleanup, left for the next sweep: %s: %w", photoPrefix, err)
	}
	// The files of copies the account received that no other account's row uses: removed before
	// the row goes, like the rest, so a failure here leaves nothing behind either.
	rows, err = pool.Query(ctx, `
		SELECT DISTINCT p.image_key FROM activity_photos p
		WHERE p.user_id = $1 AND p.image_key NOT LIKE $2 || '%'
		  AND NOT EXISTS (SELECT 1 FROM activity_photos o WHERE o.image_key = p.image_key AND o.user_id <> $1)
	`, userID, photoPrefix)
	if err != nil {
		return fmt.Errorf("received photos: %w", err)
	}
	received, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return fmt.Errorf("received photos: %w", err)
	}
	for _, key := range received {
		for _, k := range []string{key, key + "-thumb"} {
			if err := store.Remove(ctx, k); err != nil {
				return fmt.Errorf("received photo cleanup, left for the next sweep: %s: %w", k, err)
			}
		}
	}
	// httpapi's avatarKey: one object, no trailing slash to make a prefix of.
	if err := store.Remove(ctx, "avatars/"+userID); err != nil {
		return fmt.Errorf("avatar cleanup, left for the next sweep: %w", err)
	}

	if _, err := pool.Exec(ctx, `DELETE FROM users WHERE id = $1 AND deleted_at IS NOT NULL`, userID); err != nil {
		return fmt.Errorf("delete user: %w", err)
	}
	log.Info("account purge: deleted account removed", "user_id", userID)
	return nil
}
