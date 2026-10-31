package httpapi

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"log/slog"
	"regexp"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Unique web visitors per UTC day (IMPLEMENTATION.md §4.32): a page view counts its visitor as
// a hash of the address and User-Agent under the day's salt, and the daily snapshot stores the
// day's count and deletes the hashes and the salt. Nothing names a visitor, and once the salt
// is gone a hash can't be matched to anyone or to another day's.

// visitorPages are the page routes a visit counts on: what a browser navigates to, not the
// admin panel or a form's POST.
var visitorPages = map[string]bool{
	"GET /{$}": true, "GET /about": true, "GET /help": true, "GET /contacts": true, "GET /privacy": true,
	"GET /signin": true, "GET /signup": true, "GET /forgot": true, "GET /reset": true, "GET /verify": true,
	"GET /verify-pending": true, "GET /settings": true, "GET /profile": true, "GET /sync": true,
}

// notAPerson matches the User-Agents of crawlers, link previews, monitors and command-line
// clients.
var notAPerson = regexp.MustCompile(`(?i)bot|crawl|spider|slurp|preview|monitor|curl|wget|python|go-http-client|headless`)

// countsAsVisitor is whether a request to route answered with status is a person's page view:
// a page that rendered, from a browser, and not inside an app's WebView, whose use the app's
// own requests count.
func countsAsVisitor(route string, status int, userAgent string, inApp bool) bool {
	return visitorPages[route] && status == 200 && !inApp && userAgent != "" && !notAPerson.MatchString(userAgent)
}

// visitorHash is the visitor behind ip and userAgent under salt.
func visitorHash(salt []byte, ip, userAgent string) [16]byte {
	h := sha256.New()
	h.Write(salt)
	h.Write([]byte(ip))
	h.Write([]byte{0})
	h.Write([]byte(userAgent))
	var out [16]byte
	copy(out[:], h.Sum(nil))
	return out
}

// visitorCounter writes each visitor once a day per process: the salt and the hashes already
// written are kept in memory for the day.
type visitorCounter struct {
	pool *pgxpool.Pool
	log  *slog.Logger

	mu   sync.Mutex
	day  time.Time
	salt []byte
	seen map[[16]byte]bool
}

// record counts the visitor behind ip and userAgent on now's UTC day. A failed write is logged
// and forgotten, so the next view tries again.
func (c *visitorCounter) record(ctx context.Context, now time.Time, ip, userAgent string) {
	day := utcDay(now)
	c.mu.Lock()
	if !c.day.Equal(day) {
		c.day, c.salt, c.seen = day, nil, map[[16]byte]bool{}
	}
	salt := c.salt
	c.mu.Unlock()

	if salt == nil {
		var err error
		if salt, err = c.daySalt(ctx, day); err != nil {
			c.log.Error("visitor salt failed", "err", err)
			return
		}
		c.mu.Lock()
		if c.day.Equal(day) {
			c.salt = salt
		}
		c.mu.Unlock()
	}

	hash := visitorHash(salt, ip, userAgent)
	c.mu.Lock()
	if !c.day.Equal(day) || c.seen[hash] {
		c.mu.Unlock()
		return
	}
	c.seen[hash] = true
	c.mu.Unlock()

	if _, err := c.pool.Exec(ctx, `INSERT INTO visitor_days (day, hash) VALUES ($1, $2) ON CONFLICT DO NOTHING`, day, hash[:]); err != nil {
		c.log.Error("visitor count failed", "err", err)
		c.mu.Lock()
		delete(c.seen, hash)
		c.mu.Unlock()
	}
}

// daySalt is day's salt, made by whichever process asks first, so every process and a
// restarted one hash a visitor the same way.
func (c *visitorCounter) daySalt(ctx context.Context, day time.Time) ([]byte, error) {
	fresh := make([]byte, 32)
	if _, err := rand.Read(fresh); err != nil {
		return nil, err
	}
	var salt []byte
	err := c.pool.QueryRow(ctx, `
		WITH ins AS (INSERT INTO visitor_salts (day, salt) VALUES ($1, $2) ON CONFLICT DO NOTHING RETURNING salt)
		SELECT salt FROM ins UNION ALL SELECT salt FROM visitor_salts WHERE day = $1 LIMIT 1`, day, fresh).Scan(&salt)
	return salt, err
}
