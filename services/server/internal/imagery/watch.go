package imagery

import (
	"context"
	"log/slog"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// CheckInterval is how often Watch reads the usage; ProbeInterval how often it also probes a
// tile, which costs a request of the plan's own.
const (
	CheckInterval = 30 * time.Minute
	ProbeInterval = time.Hour
)

// Config is what Watch reads and probes with. A Watch with no Tiles does nothing; with no Token
// or Limit it decides on the probe alone.
type Config struct {
	Tiles   string // the XYZ template, the clients' own (SATELLITE_TILES)
	Referer string // the site the key is restricted to (APP_BASE_URL)
	Token   string // MapTiler's service token (MAPTILER_SERVICE_TOKEN)
	Limit   int64  // the plan's monthly requests (SATELLITE_MONTHLY_REQUESTS)
}

// Watch decides imagery's status on each Check and stores it, keeping the probe's failures in a
// row between checks. One process runs it: the worker. A nil Watch checks nothing.
type Watch struct {
	cfg           Config
	pool          *pgxpool.Pool
	client        *http.Client
	usageURL      string
	log           *slog.Logger
	probeFailures int
	lastProbe     time.Time
	// paused is the last decision stored, so a change is logged once rather than every check.
	paused bool
}

func NewWatch(cfg Config, pool *pgxpool.Pool, log *slog.Logger) *Watch {
	return &Watch{cfg: cfg, pool: pool, client: &http.Client{Timeout: 30 * time.Second}, usageURL: UsageURL, log: log}
}

// Check reads the usage, probes when ProbeInterval has passed since the last probe, decides and
// stores. A usage read that fails keeps the stored status as it is: no usage known is no reason
// to offer imagery again, nor to take it away.
func (w *Watch) Check(ctx context.Context, now time.Time) {
	if w == nil || w.cfg.Tiles == "" {
		return
	}
	var used, limit *int64
	if w.cfg.Token != "" && w.cfg.Limit > 0 {
		n, err := Usage(ctx, w.client, w.usageURL, w.cfg.Token)
		if err != nil {
			w.log.Error("imagery usage read failed", "err", err)
			return
		}
		used, limit = &n, &w.cfg.Limit
	}
	if now.Sub(w.lastProbe) >= ProbeInterval {
		w.lastProbe = now
		if err := Probe(ctx, w.client, w.cfg.Tiles, w.cfg.Referer); err != nil {
			w.probeFailures++
			w.log.Warn("imagery probe failed", "err", err, "in_a_row", w.probeFailures)
		} else {
			w.probeFailures = 0
		}
	}
	available, reason := Decide(used, limit, w.probeFailures)
	if err := Save(ctx, w.pool, Status{Available: available, Reason: reason, Used: used, Limit: limit, CheckedAt: now}); err != nil {
		w.log.Error("imagery status save failed", "err", err)
		return
	}
	if !available != w.paused {
		w.paused = !available
		if w.paused {
			w.log.Warn("satellite imagery paused", "reason", reason)
		} else {
			w.log.Info("satellite imagery offered again")
		}
	}
}
