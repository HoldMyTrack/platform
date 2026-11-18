package httpapi

import (
	"context"
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/HoldMyTrack/platform/services/server/internal/i18n"
	"github.com/HoldMyTrack/platform/services/server/internal/web"
	"github.com/HoldMyTrack/platform/services/server/internal/zoneinfo"
)

// The admin panel (IMPLEMENTATION.md §4.20, docs/SPEC.md FR-11): every account, and
// any one account's tracks with their ids — rendered on the server like /profile, read-only.
// Only an account with users.is_admin (granted by the `set-admin` CLI subcommand, nowhere on
// the web) gets in; everyone else, signed out or not, gets the ordinary 404 page, so the panel
// doesn't announce that it exists.

// adminActivitiesPerPage is how many tracks one page of /admin/users/{id} lists.
const adminTracksPerPage = 100

// adminUsersPerPage is how many accounts one page of /admin/users lists.
const adminUsersPerPage = 100

// adminUsersView is what templates/pages/admin.html reads from PageData.Page.
type adminUsersView struct {
	Users []adminUserRow
	// Range is "1–100 of 250"; "" when there are no accounts.
	Range    string
	PrevHref string
	NextHref string
}

type adminUserRow struct {
	ID          string
	Email       string
	DisplayName string
	SignedUp    string
	Country     string
	Timezone    string
	IsDemo      bool
	IsAdmin     bool
	Verified    bool
	Tracks      string
	// TrackCount is Tracks as a number, for its plural form.
	TrackCount int64
	// LastSeen is the last UTC day the account made a signed-in request; "" when never recorded.
	LastSeen string
	Distance string
	Clients  adminClients
}

// adminClients is which clients an account uses (IMPLEMENTATION.md §4.32).
type adminClients struct {
	Web, Android, IOS bool
}

// adminClientWindow is how long before an account's latest visit a client still counts as
// one it uses, so a client given up for another drops off instead of staying listed.
const adminClientWindow = 30 * 24 * time.Hour

// clientsInUse is each client seen within adminClientWindow of the latest of the days given,
// nil for never. Measured from the account's own latest visit, not today, so an account that
// stopped visiting still shows what it used.
func clientsInUse(web, android, ios *time.Time) adminClients {
	var latest time.Time
	for _, t := range []*time.Time{web, android, ios} {
		if t != nil && t.After(latest) {
			latest = *t
		}
	}
	recent := func(t *time.Time) bool { return t != nil && latest.Sub(*t) <= adminClientWindow }
	return adminClients{Web: recent(web), Android: recent(android), IOS: recent(ios)}
}

// adminUserView is what templates/pages/admin-user.html reads from PageData.Page.
type adminUserView struct {
	User   adminUserRow
	Tracks []adminTrackRow
	// Range is "1–100 of 250"; "" when the account has no tracks.
	Range    string
	PrevHref string
	NextHref string
}

type adminTrackRow struct {
	ID        string
	Started   string
	Type      string
	Name      string
	Distance  string
	Duration  string
	Source    string
	Countries string
	Regions   string
	Hidden    bool
	Edited    bool
}

// adminAccount is the page's account when it may see the admin panel, or nil after answering
// the request itself: the 404 page for anyone who isn't an admin, the account's own home
// (/verify-pending, /settings) for an admin who isn't past those yet.
func (s *Server) adminAccount(w http.ResponseWriter, r *http.Request) *pageAccount {
	acct, ok := s.pageAccount(w, r)
	if !ok {
		return nil
	}
	if acct == nil || !acct.info.isAdmin || acct.info.isDemo {
		s.notFound(w, r)
		return nil
	}
	if home := acct.home(); home != "/" {
		http.Redirect(w, r, home, http.StatusSeeOther)
		return nil
	}
	return acct
}

// GET /admin/users.
func (s *Server) handleAdminPage(w http.ResponseWriter, r *http.Request) {
	acct := s.adminAccount(w, r)
	if acct == nil {
		return
	}
	lang := pageLang(acct, r)
	l := i18n.Get(lang)
	view, err := s.adminUsersPage(r.Context(), l, adminPageParam(r), web.Imperial(acct.profile.Country))
	if err != nil {
		s.log.Error("admin page failed", "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	s.pages.Render(w, http.StatusOK, "admin", web.PageData{Title: l.T("meta.admin_accounts_title"), Path: "/admin/users", NoIndex: true, User: acct.user, Page: view, Lang: lang})
}

// adminPageParam is ?page=, 1 when absent or not a page number.
func adminPageParam(r *http.Request) int {
	if p, err := strconv.Atoi(r.URL.Query().Get("page")); err == nil && p > 1 {
		return p
	}
	return 1
}

// adminPages places page among total rows listed perPage at a time: its first row's offset,
// whether it lies past the last row, and whether pages come before and after it.
func adminPages(page, total, perPage int) (offset int, past, prev, next bool) {
	offset = (page - 1) * perPage
	return offset, offset >= total, page > 1, offset+perPage < total
}

// GET /admin/users/{id}.
func (s *Server) handleAdminUserPage(w http.ResponseWriter, r *http.Request) {
	acct := s.adminAccount(w, r)
	if acct == nil {
		return
	}
	userID := r.PathValue("id")
	if !uuidPattern.MatchString(userID) {
		s.notFound(w, r)
		return
	}
	imperial := web.Imperial(acct.profile.Country)
	lang := pageLang(acct, r)
	l := i18n.Get(lang)

	user, found, err := s.adminUser(r.Context(), l, userID, imperial)
	if err == nil && !found {
		s.notFound(w, r)
		return
	}
	var view adminUserView
	if err == nil {
		view, err = s.adminUserTracks(r.Context(), l, user, adminPageParam(r), imperial)
	}
	if err != nil {
		s.log.Error("admin user page failed", "err", err, "user_id", userID)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	s.pages.Render(w, http.StatusOK, "admin-user", web.PageData{Title: l.T("meta.admin_user_title", "name", adminUserLabel(view.User)), Path: r.URL.Path, NoIndex: true, User: acct.user, Page: view, Lang: lang})
}

// adminUsersSQL selects adminUserRow's columns, newest first, for the open accounts whose ids
// picked selects. Counts and distance are over every track, totalled only for those: picked
// is a subquery so a page's LIMIT applies before the totals, which a join in the same FROM
// would compute for every account first.
func adminUsersSQL(picked string) string {
	return `
	SELECT u.id, u.email, COALESCE(u.display_name, ''), u.created_at, COALESCE(u.country, ''),
	       u.timezone, u.is_admin, u.email_verified, u.last_seen_at,
	       u.web_seen_at, u.android_seen_at, u.ios_seen_at, a.n, a.meters
	FROM (` + picked + `) p
	JOIN users u ON u.id = p.id
	CROSS JOIN LATERAL (
		SELECT count(*), COALESCE(sum(distance_meters), 0)::float8
		FROM activities WHERE user_id = u.id
	) a (n, meters)
	ORDER BY u.created_at DESC, u.id`
}

// adminUsersPage is one page of every account, newest first.
func (s *Server) adminUsersPage(ctx context.Context, l *i18n.Localizer, page int, imperial bool) (adminUsersView, error) {
	var view adminUsersView
	var total int
	if err := s.pool.QueryRow(ctx, `SELECT count(*) FROM users WHERE deleted_at IS NULL`).Scan(&total); err != nil {
		return view, fmt.Errorf("admin: count users: %w", err)
	}
	offset, past, prev, next := adminPages(page, total, adminUsersPerPage)
	if total == 0 {
		return view, nil
	}
	if past {
		// A page past the end (a stale link after deletions): empty, with a way back.
		view.Range = l.T("admin.range_empty_accounts")
		view.PrevHref = adminUsersHref(1)
		return view, nil
	}
	users, err := s.adminUserRows(ctx, l, imperial, adminUsersSQL(`
		SELECT id FROM users WHERE deleted_at IS NULL
		ORDER BY created_at DESC, id LIMIT $1 OFFSET $2`), adminUsersPerPage, offset)
	if err != nil {
		return view, err
	}
	view.Users = users
	view.Range = adminRange(l, offset, len(users), total)
	if prev {
		view.PrevHref = adminUsersHref(page - 1)
	}
	if next {
		view.NextHref = adminUsersHref(page + 1)
	}
	return view, nil
}

// adminUser is the account userID, a UUID, if it exists and isn't closed.
func (s *Server) adminUser(ctx context.Context, l *i18n.Localizer, userID string, imperial bool) (adminUserRow, bool, error) {
	users, err := s.adminUserRows(ctx, l, imperial, adminUsersSQL(`
		SELECT id FROM users WHERE deleted_at IS NULL AND id = $1::uuid`), userID)
	if err != nil || len(users) == 0 {
		return adminUserRow{}, false, err
	}
	return users[0], true, nil
}

func (s *Server) adminUserRows(ctx context.Context, l *i18n.Localizer, imperial bool, sql string, args ...any) ([]adminUserRow, error) {
	rows, err := s.pool.Query(ctx, sql, args...)
	if err != nil {
		return nil, fmt.Errorf("admin: list users: %w", err)
	}
	defer rows.Close()
	var users []adminUserRow
	for rows.Next() {
		var u adminUserRow
		var created time.Time
		var lastSeen, webSeen, androidSeen, iosSeen *time.Time
		var count int64
		var meters float64
		if err := rows.Scan(&u.ID, &u.Email, &u.DisplayName, &created, &u.Country,
			&u.Timezone, &u.IsAdmin, &u.Verified,
			&lastSeen, &webSeen, &androidSeen, &iosSeen, &count, &meters); err != nil {
			return nil, fmt.Errorf("admin: scan user: %w", err)
		}
		u.IsDemo = u.ID == DemoCustomerUserID
		u.Clients = clientsInUse(webSeen, androidSeen, iosSeen)
		loc := adminLocation(u.Timezone)
		u.SignedUp = created.In(loc).Format("2006-01-02")
		u.TrackCount = count
		u.Tracks = l.Int(count)
		u.Distance = web.FormatTotalDistance(l, meters, imperial)
		if lastSeen != nil {
			u.LastSeen = lastSeen.In(loc).Format("2006-01-02")
		}
		users = append(users, u)
	}
	return users, rows.Err()
}

// adminUserActivities is one page of u's tracks, newest first — hidden ones included,
// marked as such, since the panel is for seeing what's actually stored.
func (s *Server) adminUserTracks(ctx context.Context, l *i18n.Localizer, u adminUserRow, page int, imperial bool) (adminUserView, error) {
	view := adminUserView{User: u}
	total := int(u.TrackCount)
	offset, past, prev, next := adminPages(page, total, adminTracksPerPage)
	if total == 0 {
		return view, nil
	}
	if past {
		// A page past the end (a stale link after deletions): empty, with a way back.
		view.Range = l.T("admin.range_empty")
		view.PrevHref = adminUserHref(u.ID, 1)
		return view, nil
	}

	rows, err := s.pool.Query(ctx, `
		SELECT a.id, to_char(a.started_at AT TIME ZONE a.timezone, 'YYYY-MM-DD HH24:MI') || ' ' || a.timezone,
		       a.activity_type, COALESCE(a.name, ''),
		       COALESCE(a.distance_meters, 0)::float8, COALESCE(a.duration_seconds, 0), a.source,
		       a.trajectory IS NULL, a.track_edit IS NOT NULL,
		       COALESCE((SELECT string_agg(c.name, ', ' ORDER BY c.name)
		                 FROM activity_country ac JOIN admin_countries c ON c.id = ac.country_id
		                 WHERE ac.activity_id = a.id), ''),
		       COALESCE((SELECT string_agg(rg.name, ', ' ORDER BY rg.name)
		                 FROM activity_region ar JOIN admin_regions rg ON rg.id = ar.region_id
		                 WHERE ar.activity_id = a.id), '')
		FROM activities a
		WHERE a.user_id = $1
		ORDER BY a.started_at DESC, a.id
		LIMIT $2 OFFSET $3
	`, u.ID, adminTracksPerPage, offset)
	if err != nil {
		return view, fmt.Errorf("admin: list activities: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var a adminTrackRow
		var meters float64
		var seconds int64
		if err := rows.Scan(&a.ID, &a.Started, &a.Type, &a.Name, &meters, &seconds, &a.Source,
			&a.Hidden, &a.Edited, &a.Countries, &a.Regions); err != nil {
			return view, fmt.Errorf("admin: scan activity: %w", err)
		}
		a.Distance = web.FormatDistance(l, meters, imperial)
		a.Duration = adminDuration(seconds)
		view.Tracks = append(view.Tracks, a)
	}
	if err := rows.Err(); err != nil {
		return view, fmt.Errorf("admin: list activities: %w", err)
	}

	view.Range = adminRange(l, offset, len(view.Tracks), total)
	if prev {
		view.PrevHref = adminUserHref(u.ID, page-1)
	}
	if next {
		view.NextHref = adminUserHref(u.ID, page+1)
	}
	return view, nil
}

// adminRange is "1–100 of 250".
func adminRange(l *i18n.Localizer, offset, n, total int) string {
	return l.T("admin.range", "from", offset+1, "to", offset+n, "total", total)
}

func adminUsersHref(page int) string {
	if page <= 1 {
		return "/admin/users"
	}
	return fmt.Sprintf("/admin/users?page=%d", page)
}

func adminUserHref(userID string, page int) string {
	if page <= 1 {
		return "/admin/users/" + userID
	}
	return fmt.Sprintf("/admin/users/%s?page=%d", userID, page)
}

// adminUserLabel names an account in a title: its display name, else its email.
func adminUserLabel(u adminUserRow) string {
	if u.DisplayName != "" {
		return u.DisplayName
	}
	return u.Email
}

// adminDuration is "0:42" or "12:05" — hours and minutes, which is all a list needs.
func adminDuration(seconds int64) string {
	m := (seconds + 30) / 60
	return fmt.Sprintf("%d:%02d", m/60, m%60)
}

// adminLocation is the account's own timezone, so dates read as that account saw them.
func adminLocation(tz string) *time.Location {
	return zoneinfo.LoadOr(tz, time.UTC)
}

// SetAdmin grants or revokes the admin panel for the account with this email — the
// `set-admin` CLI subcommand, the only thing that writes users.is_admin. A demo account can't
// be made one: a demo session never reaches the panel anyway (adminAccount).
func SetAdmin(ctx context.Context, pool *pgxpool.Pool, rawEmail string, admin bool) error {
	email, err := normalizeEmail(rawEmail)
	if err != nil {
		return err
	}
	tag, err := pool.Exec(ctx,
		`UPDATE users SET is_admin = $2 WHERE email = $1 AND id <> $3`, email, admin, DemoCustomerUserID)
	if err != nil {
		return fmt.Errorf("set admin: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("set admin: no account with email %q", email)
	}
	return nil
}
