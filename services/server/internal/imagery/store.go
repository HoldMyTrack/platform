package imagery

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Save stores s as the one imagery_status row (docs/IMPLEMENTATION.md §3.31).
func Save(ctx context.Context, pool *pgxpool.Pool, s Status) error {
	_, err := pool.Exec(ctx, `
		INSERT INTO imagery_status (id, available, reason, used, request_limit, checked_at)
		VALUES (true, $1, $2, $3, $4, $5)
		ON CONFLICT (id) DO UPDATE SET available = $1, reason = $2, used = $3, request_limit = $4, checked_at = $5`,
		s.Available, s.Reason, s.Used, s.Limit, s.CheckedAt)
	if err != nil {
		return fmt.Errorf("imagery: save: %w", err)
	}
	return nil
}

// Load is the stored status, and false when there is none yet: imagery is then offered.
func Load(ctx context.Context, pool *pgxpool.Pool) (Status, bool, error) {
	var s Status
	err := pool.QueryRow(ctx, `SELECT available, reason, used, request_limit, checked_at FROM imagery_status`).
		Scan(&s.Available, &s.Reason, &s.Used, &s.Limit, &s.CheckedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Status{Available: true}, false, nil
	}
	if err != nil {
		return Status{}, false, fmt.Errorf("imagery: load: %w", err)
	}
	return s, true, nil
}
