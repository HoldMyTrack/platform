package httpapi

// Covers docs/SPEC.md FR-12.4 (the admin statistics page).

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/HoldMyTrack/platform/services/server/internal/i18n"
	"github.com/HoldMyTrack/platform/services/server/internal/web"
)

func TestParseStatsRange(t *testing.T) {
	for q, want := range map[string]int{"": 90, "30": 30, "90": 90, "365": 365, "7": 90, "abc": 90, "-30": 90} {
		if got := parseStatsRange(q); got != want {
			t.Errorf("parseStatsRange(%q) = %d, want %d", q, got, want)
		}
	}
}

func TestStatsRangesMarkCurrentAndDropDefaultFromHref(t *testing.T) {
	got := statsRanges(30)
	want := []adminStatsRange{
		{Days: 30, Href: "/admin?days=30", Current: true},
		{Days: 90, Href: "/admin"},
		{Days: 365, Href: "/admin?days=365"},
	}
	if len(got) != len(want) {
		t.Fatalf("got %v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("range %d = %+v, want %+v", i, got[i], want[i])
		}
	}
}

func TestStatsLastDayIsYesterdayUTC(t *testing.T) {
	now := time.Date(2026, 10, 30, 1, 30, 0, 0, time.FixedZone("EDT", -4*3600)) // 05:30 UTC
	if got, want := statsLastDay(now), time.Date(2026, 10, 29, 0, 0, 0, 0, time.UTC); !got.Equal(want) {
		t.Errorf("statsLastDay = %v, want %v", got, want)
	}
}

func TestBuildSeriesLeavesGaps(t *testing.T) {
	from := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	values := map[time.Time]float64{from: 3, from.AddDate(0, 0, 2): 0}
	got := buildSeries(values, from, 3)
	if len(got) != 3 {
		t.Fatalf("len %d", len(got))
	}
	if !got[0].Has || got[0].Value != 3 {
		t.Errorf("day 0 = %+v", got[0])
	}
	if got[1].Has {
		t.Errorf("day 1 has no snapshot, got %+v", got[1])
	}
	if !got[2].Has || got[2].Value != 0 || !got[2].Day.Equal(from.AddDate(0, 0, 2)) {
		t.Errorf("day 2 = %+v", got[2])
	}
}

func TestNiceCeil(t *testing.T) {
	for v, want := range map[float64]float64{0: 1, 0.4: 1, 1: 1, 1.5: 2, 3: 5, 7: 10, 10: 10, 11: 20, 240: 500, 1000: 1000} {
		if got := niceCeil(v); got != want {
			t.Errorf("niceCeil(%v) = %v, want %v", v, got, want)
		}
	}
}

func TestBarLayout(t *testing.T) {
	points := []statsPoint{{Value: 10, Has: true}, {}, {Value: 0, Has: true}, {Value: 5, Has: true}}
	bars := barLayout(points, 10, 400, 100)
	if len(bars) != 4 {
		t.Fatalf("len %d", len(bars))
	}
	for i, b := range bars {
		if b.X != float64(i)*100 || b.W != 100 {
			t.Errorf("bar %d hit area at %v width %v", i, b.X, b.W)
		}
	}
	if !strings.HasPrefix(bars[0].Path, "M1.00 100.00V4.00") {
		t.Errorf("full bar path %q, want from the baseline to the top", bars[0].Path)
	}
	if bars[1].Path != "" {
		t.Errorf("a gap draws nothing, got %q", bars[1].Path)
	}
	if !strings.HasPrefix(bars[2].Path, "M201.00 100.00V") || !strings.Contains(bars[2].Path, " 99.00H") {
		t.Errorf("a zero draws a 1-unit stub, got %q", bars[2].Path)
	}
	if !strings.Contains(bars[3].Path, " 50.00H") {
		t.Errorf("half bar path %q, want its top at 50", bars[3].Path)
	}
	if barLayout(nil, 1, 400, 100) != nil {
		t.Error("no points, no bars")
	}
}

func TestLineLayout(t *testing.T) {
	points := []statsPoint{{Value: 10, Has: true}, {Value: 5, Has: true}, {}, {Value: 0, Has: true}, {}}
	line, days := lineLayout(points, 10, 500, 100)
	if line != "M50.00 0.00L150.00 50.00M350.00 100.00" {
		t.Errorf("line = %q, want a break at the missing day", line)
	}
	if len(days) != 5 || days[2].Dot || !days[3].Dot || days[3].CY != 100 {
		t.Fatalf("days = %+v", days)
	}
	if days[0].Alone || days[1].Alone || !days[3].Alone {
		t.Errorf("alone: %v %v %v, want only the day between gaps", days[0].Alone, days[1].Alone, days[3].Alone)
	}
	if days[4].X != 400 || days[4].W != 100 {
		t.Errorf("hit area of a gap at %v width %v", days[4].X, days[4].W)
	}
	if l, d := lineLayout(nil, 1, 500, 100); l != "" || d != nil {
		t.Error("no points, no line")
	}
}

func TestStatsChartView(t *testing.T) {
	l := i18n.Get("")
	from := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	points := buildSeries(map[time.Time]float64{from: 3, from.AddDate(0, 0, 1): 4}, from, 3)

	flow := statsChartView(l, adminStatsChart{titleKey: "admin.stats_signups", key: "signups", flow: true}, points)
	if flow.Title != "Signups" || flow.Total != "7" || flow.Latest != "4" || flow.Max != "5" || flow.Half != "2.5" {
		t.Errorf("flow chart = %+v", flow)
	}
	if flow.First != "2026-10-01" || flow.Last != "2026-10-03" || flow.Bars[1].Label != "2026-10-02: 4" || flow.Bars[2].Label != "2026-10-03: —" {
		t.Errorf("flow chart dates/labels = %q %q %q %q", flow.First, flow.Last, flow.Bars[1].Label, flow.Bars[2].Label)
	}

	if empty := statsChartView(l, adminStatsChart{titleKey: "admin.stats_visitors", flow: true}, buildSeries(nil, from, 2)); empty.Latest != "—" || empty.Total != "—" {
		t.Errorf("no snapshot: Latest %q, Total %q, want —", empty.Latest, empty.Total)
	}

	state := statsChartView(l, adminStatsChart{titleKey: "admin.stats_accounts", key: "accounts", line: true}, points[:2])
	if state.Total != "" || state.Latest != "4" || state.Max != "5" || state.Line == "" || state.Bars[0].Path != "" || !state.Bars[0].Dot {
		t.Errorf("line chart = %+v", state)
	}
	if flow.Line != "" || flow.Bars[0].Path == "" {
		t.Errorf("bar chart drew a line: %+v", flow)
	}
}

func TestAdminStatsPageSignedOutIsNotFound(t *testing.T) {
	s := newPagesTestServer(t)
	rec := httptest.NewRecorder()
	s.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/admin", nil))
	if rec.Code != http.StatusNotFound || !strings.Contains(rec.Body.String(), "Page not found") {
		t.Errorf("status %d, want the ordinary 404 page", rec.Code)
	}
}

func TestAdminStatsPageRenders(t *testing.T) {
	s := newPagesTestServer(t)
	l := i18n.Get("")
	from := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	chart := statsChartView(l, adminStatsChart{titleKey: "admin.stats_signups", key: "signups", flow: true}, buildSeries(map[time.Time]float64{from: 3}, from, 2))
	rec := httptest.NewRecorder()
	s.pages.Render(rec, http.StatusOK, "admin-stats", web.PageData{Title: "Statistics", Path: "/admin", NoIndex: true, User: &web.User{Email: "admin@example.com", IsAdmin: true},
		Page: adminStatsView{Ranges: statsRanges(90), Charts: []adminStatsChartView{chart}}})
	body := rec.Body.String()
	for _, want := range []string{"Signups", "<title>2026-10-01: 3</title>", "<strong>90 days</strong>", `href="/admin?days=30"`, `href="/admin/users"`, `viewBox="0 0 720 160"`} {
		if !strings.Contains(body, want) {
			t.Errorf("stats page: missing %q", want)
		}
	}
}
