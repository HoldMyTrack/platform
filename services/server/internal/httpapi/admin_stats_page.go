package httpapi

import (
	"context"
	"fmt"
	"math"
	"net/http"
	"strconv"
	"time"

	"github.com/HoldMyTrack/platform/services/server/internal/i18n"
	"github.com/HoldMyTrack/platform/services/server/internal/web"
)

// The admin panel's statistics page (docs/SPEC.md FR-12.4): a bar chart per daily_stats key
// (IMPLEMENTATION.md §4.32), drawn on the server as inline SVG. Postgres is the record, so the
// page reaches past the ~14 days Grafana keeps.

// adminStatsChart is one chart: a daily_stats key and its title. flow is a stat counted over
// each day (internal/stats' flow kind), whose days add up to a total over the range.
type adminStatsChart struct {
	titleKey string
	key      string
	flow     bool
}

var adminStatsCharts = []adminStatsChart{
	{titleKey: "admin.stats_signups", key: "signups", flow: true},
	{titleKey: "admin.stats_active_1d", key: "active_1d"},
	{titleKey: "admin.stats_accounts", key: "accounts"},
	{titleKey: "admin.stats_active_30d", key: "active_30d"},
	{titleKey: "admin.stats_activities_added", key: "activities_added", flow: true},
}

// adminStatsRanges are the page's ?days= choices, adminStatsDefaultDays when there's none.
var adminStatsRanges = []int{30, 90, 365}

const adminStatsDefaultDays = 90

// The chart's SVG coordinates: the viewBox scales to the page's width.
const (
	adminChartWidth  = 720.0
	adminChartHeight = 160.0
)

// adminStatsView is what templates/pages/admin-stats.html reads from PageData.Page.
type adminStatsView struct {
	Ranges []adminStatsRange
	Charts []adminStatsChartView
}

type adminStatsRange struct {
	Days    int
	Href    string
	Current bool
}

type adminStatsChartView struct {
	Title string
	// Latest is the newest snapshot's value in the range, "—" when there's none; Total is the
	// sum over the range for a flow stat, "" otherwise.
	Latest string
	Total  string
	// Max and Half label the top and middle grid lines.
	Max   string
	Half  string
	Bars  []adminStatsBar
	First string
	Last  string
	Width float64
	// Height is the plot's height, MidY its middle grid line's.
	Height float64
	MidY   float64
}

// adminStatsBar is one day: a hit area the full height of the plot carrying the tooltip, and
// the bar's path, "" on a day with no snapshot.
type adminStatsBar struct {
	X, W  float64
	Path  string
	Label string
}

// statsPoint is one day of a series; Has is false on a day without a snapshot.
type statsPoint struct {
	Day   time.Time
	Value float64
	Has   bool
}

// GET /admin/stats.
func (s *Server) handleAdminStatsPage(w http.ResponseWriter, r *http.Request) {
	acct := s.adminAccount(w, r)
	if acct == nil {
		return
	}
	lang := pageLang(acct, r)
	l := i18n.Get(lang)
	days := parseStatsRange(r.URL.Query().Get("days"))
	last := statsLastDay(time.Now())
	from := last.AddDate(0, 0, -(days - 1))
	values, err := s.adminStatsValues(r.Context(), from)
	if err != nil {
		s.log.Error("admin stats page failed", "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	view := adminStatsView{Ranges: statsRanges(days)}
	for _, c := range adminStatsCharts {
		view.Charts = append(view.Charts, statsChartView(l, c, buildSeries(values[c.key], from, days)))
	}
	s.pages.Render(w, http.StatusOK, "admin-stats", web.PageData{Title: l.T("meta.admin_stats_title"), Path: "/admin/stats", NoIndex: true, User: acct.user, Page: view, Lang: lang})
}

// adminStatsValues reads every chart's values from from on, by key and day.
func (s *Server) adminStatsValues(ctx context.Context, from time.Time) (map[string]map[time.Time]float64, error) {
	keys := make([]string, len(adminStatsCharts))
	for i, c := range adminStatsCharts {
		keys[i] = c.key
	}
	rows, err := s.pool.Query(ctx, `SELECT day, key, value FROM daily_stats WHERE key = ANY($1) AND day >= $2::date`, keys, from)
	if err != nil {
		return nil, fmt.Errorf("admin stats: %w", err)
	}
	defer rows.Close()
	values := map[string]map[time.Time]float64{}
	for rows.Next() {
		var day time.Time
		var key string
		var v float64
		if err := rows.Scan(&day, &key, &v); err != nil {
			return nil, fmt.Errorf("admin stats: scan: %w", err)
		}
		if values[key] == nil {
			values[key] = map[time.Time]float64{}
		}
		values[key][utcDay(day)] = v
	}
	return values, rows.Err()
}

// parseStatsRange is ?days=, one of adminStatsRanges, else the default.
func parseStatsRange(q string) int {
	n, err := strconv.Atoi(q)
	if err == nil {
		for _, d := range adminStatsRanges {
			if d == n {
				return n
			}
		}
	}
	return adminStatsDefaultDays
}

// statsRanges are the range links, current marked.
func statsRanges(current int) []adminStatsRange {
	out := make([]adminStatsRange, 0, len(adminStatsRanges))
	for _, d := range adminStatsRanges {
		href := "/admin/stats"
		if d != adminStatsDefaultDays {
			href += "?days=" + strconv.Itoa(d)
		}
		out = append(out, adminStatsRange{Days: d, Href: href, Current: d == current})
	}
	return out
}

// statsLastDay is the newest day a snapshot can exist for at now: yesterday, UTC.
func statsLastDay(now time.Time) time.Time {
	return utcDay(now).AddDate(0, 0, -1)
}

// utcDay is t's UTC day at midnight.
func utcDay(t time.Time) time.Time {
	y, m, d := t.UTC().Date()
	return time.Date(y, m, d, 0, 0, 0, 0, time.UTC)
}

// buildSeries is days days of values from from, a day with no value left as a gap.
func buildSeries(values map[time.Time]float64, from time.Time, days int) []statsPoint {
	points := make([]statsPoint, days)
	for i := range points {
		day := from.AddDate(0, 0, i)
		v, ok := values[day]
		points[i] = statsPoint{Day: day, Value: v, Has: ok}
	}
	return points
}

// niceCeil is the smallest 1, 2 or 5 × 10ⁿ at or above v, and 1 for nothing above zero.
func niceCeil(v float64) float64 {
	if v <= 1 {
		return 1
	}
	p := math.Pow(10, math.Floor(math.Log10(v)))
	for _, m := range []float64{1, 2, 5, 10} {
		if m*p >= v {
			return m * p
		}
	}
	return 10 * p
}

// barLayout places one bar per point across width, scaled to scaleMax over height: 2 units
// apart, the top end rounded, and a zero drawn as a 1-unit stub so it reads apart from a gap.
func barLayout(points []statsPoint, scaleMax, width, height float64) []adminStatsBar {
	if len(points) == 0 {
		return nil
	}
	step := width / float64(len(points))
	gap := math.Min(2, step/4)
	bars := make([]adminStatsBar, len(points))
	for i, p := range points {
		x := float64(i) * step
		b := adminStatsBar{X: x, W: step}
		if p.Has {
			h := math.Max(1, p.Value/scaleMax*height)
			b.Path = barPath(x+gap/2, height-h, step-gap, h)
		}
		bars[i] = b
	}
	return bars
}

// barPath is a bar from (x, y) w wide and h tall, its top corners rounded up to 4 units.
func barPath(x, y, w, h float64) string {
	r := math.Min(4, math.Min(w/2, h))
	return fmt.Sprintf("M%.2f %.2fV%.2fA%.2f %.2f 0 0 1 %.2f %.2fH%.2fA%.2f %.2f 0 0 1 %.2f %.2fV%.2fZ",
		x, y+h, y+r, r, r, x+r, y, x+w-r, r, r, x+w, y+r, y+h)
}

// statsChartView is chart c over points, labelled in l's language.
func statsChartView(l *i18n.Localizer, c adminStatsChart, points []statsPoint) adminStatsChartView {
	count := func(v float64) string { return l.Int(int64(math.Round(v))) }
	peak, total := 0.0, 0.0
	for _, p := range points {
		if p.Has {
			peak = math.Max(peak, p.Value)
			total += p.Value
		}
	}
	scaleMax := niceCeil(peak)
	v := adminStatsChartView{
		Title:  l.T(c.titleKey),
		Latest: "—",
		Max:    count(scaleMax),
		Half:   l.Float(scaleMax/2, 0),
		Bars:   barLayout(points, scaleMax, adminChartWidth, adminChartHeight),
		Width:  adminChartWidth,
		Height: adminChartHeight,
		MidY:   adminChartHeight / 2,
	}
	if scaleMax/2 != math.Trunc(scaleMax/2) {
		v.Half = l.Float(scaleMax/2, 1)
	}
	if n := len(points); n > 0 {
		v.First = points[0].Day.Format(time.DateOnly)
		v.Last = points[n-1].Day.Format(time.DateOnly)
	}
	for i := len(points) - 1; i >= 0; i-- {
		if points[i].Has {
			v.Latest = count(points[i].Value)
			break
		}
	}
	if c.flow {
		v.Total = count(total)
	}
	for i, p := range points {
		value := "—"
		if p.Has {
			value = count(p.Value)
		}
		v.Bars[i].Label = p.Day.Format(time.DateOnly) + ": " + value
	}
	return v
}
