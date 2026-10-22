package httpapi

import (
	"net"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// rateLimitsOff lets every fixedWindowLimiter through, the per-account and per-address limits
// alike, for local development only: config's RATE_LIMITS=off, refused for an APP_BASE_URL
// that isn't local. The R2 budget (internal/budget) is a cost cap, not one of these.
var rateLimitsOff atomic.Bool

// SetRateLimitsOff turns every per-account and per-address request limit off, or back on.
func SetRateLimitsOff(off bool) { rateLimitsOff.Store(off) }

// defaultTilesPerMinute is how many tile requests one account may make in a minute, across
// every /tiles/v1 layer. A pan fetches dozens at once and a high-resolution map export
// (apps/web/src/map/exportMap.ts) many more in one burst, failing outright on a single refused
// tile, so this sits far above any person's use: it stops a script that ignores the clients'
// per-version tile cache (§4.2.6), each Fog or Heatmap tile of which is an R2 read.
// TILES_PER_MINUTE overrides it, for a load test's target.
const defaultTilesPerMinute = 1200

// syncRequestsPerHour bounds `POST /v1/sync/activities` per account. A batch carries up to
// maxSyncBatchActivities, so a first sync of a long Health Connect history still brings in
// thousands an hour; the upload limit (defaultUploadsPerHour) doesn't reach this path.
const syncRequestsPerHour = 60

// syncActivitiesPerHour bounds the activities `POST /v1/sync/activities` takes from one account
// in an hour, beside syncRequestsPerHour's count of requests: at 100 a batch, that one alone
// would take 6,000 an hour. A phone lists three months of Health Connect sessions and its own
// recordings, a few hundred at most, so this only slows an account syncing, deleting and
// syncing again, which costs a render each time and stores nothing (IMPLEMENTATION.md §5.7).
const syncActivitiesPerHour = 1000

// defaultSignupsPerHour bounds the accounts one address creates with an email and password in
// an hour. Each sends a verification email to whatever address was typed, and every
// per-account limit counts one account. Only an account created counts, so a mistyped
// password or a taken address costs nothing; Google and Facebook sign-in, whose providers
// gate account creation themselves, aren't counted. SIGNUPS_PER_HOUR overrides it, for a load
// test creating its accounts.
const defaultSignupsPerHour = 5

// trackPointsPerHour bounds `GET /v1/activities/track-points/{id}` per account: each request
// reads an original upload from object storage and parses it, and a person opens the track
// editor a few times an hour at most.
const trackPointsPerHour = 120

// rateKey is who a per-account limit counts a request against: the account, or for the demo
// account, which every visitor shares (DemoCustomerUserID), the visitor's address, so one
// heavy visitor doesn't use up everyone else's demo.
func rateKey(info authInfo, ip string) string {
	if info.isDemo {
		return "ip:" + ip
	}
	return info.userID
}

// limited reports whether l refuses r, answering the 429 itself when it does, with msgKey's
// message naming the limit as {max}.
func limited(w http.ResponseWriter, r *http.Request, l *fixedWindowLimiter, msgKey string) bool {
	if l.allow(rateKey(authInfoFromContext(r.Context()), clientIP(r))) {
		return false
	}
	httpErrorT(w, r, http.StatusTooManyRequests, msgKey, "max", l.limit)
	return true
}

// tile registers one /tiles/v1 layer: signed in and verified, and inside the account's tile
// limit. A refused tile is only a gap the map fills on its next pan, so it carries a
// Retry-After rather than a message anyone sees.
func (s *Server) tile(path string, h http.HandlerFunc) {
	s.mux.HandleFunc(tileRoute("GET", path), s.requireVerified(func(w http.ResponseWriter, r *http.Request) {
		if !s.tileLimiter.allow(rateKey(authInfoFromContext(r.Context()), clientIP(r))) {
			w.Header().Set("Retry-After", "60")
			httpErrorT(w, r, http.StatusTooManyRequests, "error.tile_rate_limit")
			return
		}
		h(w, r)
	}))
}

// SetSignupsPerHour replaces the per-address signup limit (defaultSignupsPerHour), starting
// every address's count afresh.
func (s *Server) SetSignupsPerHour(n int) {
	s.signupLimiter = newFixedWindowLimiter(n, time.Hour)
}

// SetTilesPerMinute replaces the per-account tile limit (defaultTilesPerMinute), starting
// every account's count afresh.
func (s *Server) SetTilesPerMinute(n int) {
	s.tileLimiter = newFixedWindowLimiter(n, time.Minute)
}

type fixedWindowLimiter struct {
	mu     sync.Mutex
	limit  int
	window time.Duration
	counts map[string]*windowCount
}

type windowCount struct {
	count      int
	windowFrom time.Time
}

func newFixedWindowLimiter(limit int, window time.Duration) *fixedWindowLimiter {
	return &fixedWindowLimiter{limit: limit, window: window, counts: make(map[string]*windowCount)}
}

// allow counts one request against key and reports whether it is within the limit — the
// limit on every request, for the endpoints that mail or create something.
func (l *fixedWindowLimiter) allow(key string) bool {
	if rateLimitsOff.Load() {
		return true
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	c := l.current(key)
	if c.count >= l.limit {
		return false
	}
	c.count++
	return true
}

// allowN is allow for n at once: it counts all n and reports true when they fit in what's left
// of key's window, and counts nothing and reports false when they don't.
func (l *fixedWindowLimiter) allowN(key string, n int) bool {
	if rateLimitsOff.Load() {
		return true
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	c := l.current(key)
	if c.count+n > l.limit {
		return false
	}
	c.count += n
	return true
}

// exceeded and hit split allow for a limit on failures only (sign-in): exceeded checks
// without counting, hit counts one.
func (l *fixedWindowLimiter) exceeded(key string) bool {
	if rateLimitsOff.Load() {
		return false
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.current(key).count >= l.limit
}

func (l *fixedWindowLimiter) hit(key string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.current(key).count++
}

// current is key's count in its live window, starting a fresh one if it has none. It also
// sweeps every stale entry on each call, so the map stays bounded by recently active callers
// rather than growing forever from one-off addresses that never return. The caller holds mu.
func (l *fixedWindowLimiter) current(key string) *windowCount {
	now := time.Now()
	for k, c := range l.counts {
		if now.Sub(c.windowFrom) > l.window {
			delete(l.counts, k)
		}
	}
	c, ok := l.counts[key]
	if !ok {
		c = &windowCount{windowFrom: now}
		l.counts[key] = c
	}
	return c
}

// clientIP is the address a per-caller limit keys on. In production every request arrives
// through Caddy (apps/web/docker/Caddyfile; api publishes no port), so RemoteAddr is Caddy's
// container address for every visitor, and a limit keyed on it was one limit shared by the
// whole site. Caddy, trusting no proxy ahead of it, discards any X-Forwarded-For a client
// sends and sets its own, the address it was connected from; the last entry is taken, so a
// proxy that appends instead would still be read correctly. The header is believed only from
// a private or loopback peer — the proxy on the container network; a caller reaching this
// server directly gets its own RemoteAddr and can't claim a different one.
func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	peer := net.ParseIP(host)
	if peer == nil || !(peer.IsPrivate() || peer.IsLoopback()) {
		return host
	}
	values := r.Header.Values("X-Forwarded-For")
	if len(values) == 0 {
		return host
	}
	last := values[len(values)-1]
	if i := strings.LastIndex(last, ","); i >= 0 {
		last = last[i+1:]
	}
	if ip := net.ParseIP(strings.TrimSpace(last)); ip != nil {
		return ip.String()
	}
	return host
}
