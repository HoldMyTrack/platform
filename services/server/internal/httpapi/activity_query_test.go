package httpapi

import (
	"math"
	"net/url"
	"testing"
	"time"
)

func query(t *testing.T, raw string) url.Values {
	t.Helper()
	q, err := url.ParseQuery(raw)
	if err != nil {
		t.Fatal(err)
	}
	return q
}

func TestParseActivityFilter(t *testing.T) {
	f, err := parseActivityFilter(query(t, "from=2026-03-10&to=2026-03-12&types=running,walking&story=00000000-0000-4000-8000-000000000001"))
	if err != nil || *f.From != "2026-03-10" || *f.To != "2026-03-12" || len(f.Types) != 2 || f.Story == nil {
		t.Fatalf("full filter: %+v %v", f, err)
	}
	// Absent means no restriction, which the queries read as NULL: nil, not empty.
	if f, err := parseActivityFilter(query(t, "")); err != nil || f.From != nil || f.To != nil || f.Types != nil || f.Story != nil {
		t.Fatalf("empty filter: %+v %v", f, err)
	}
	for _, bad := range []string{"from=2026-3-10", "to=yesterday", "story=42"} {
		if _, err := parseActivityFilter(query(t, bad)); err == nil {
			t.Errorf("%s: parsed, want refused", bad)
		}
	}
}

func TestParseDayPage(t *testing.T) {
	limit, before, err := parseDayPage(query(t, "days=30&before=2026-05-01"))
	if err != nil || limit != 30 || before == nil || *before != "2026-05-01" {
		t.Fatalf("got %d %v %v", limit, before, err)
	}
	if limit, before, err := parseDayPage(query(t, "days=5000")); err != nil || limit != maxHistogramDays || before != nil {
		t.Fatalf("over the cap: got %d %v %v", limit, before, err)
	}
	for _, bad := range []string{"", "days=0", "days=-3", "days=x", "days=5&before=May"} {
		if _, _, err := parseDayPage(query(t, bad)); err == nil {
			t.Errorf("%q: parsed, want refused", bad)
		}
	}
}

func TestDateWindow(t *testing.T) {
	tokyo, _ := time.LoadLocation("Asia/Tokyo")
	// 20:00 UTC on the 9th is already the 10th in Tokyo.
	now := time.Date(2026, 3, 9, 20, 0, 0, 0, time.UTC)
	for _, tc := range []struct {
		query, first, last string
	}{
		{"", "2025-03-10", "2026-03-10"},
		{"to=2026-01-31", "2025-01-31", "2026-01-31"},
		{"from=2026-02-01", "2026-02-01", "2026-03-10"},
		{"from=2026-02-01&to=2026-02-01", "2026-02-01", "2026-02-01"},
	} {
		first, last, err := dateWindow(query(t, tc.query), now, tokyo)
		if err != nil || first.Format(dateLayout) != tc.first || last.Format(dateLayout) != tc.last || first.Location() != tokyo {
			t.Errorf("%q: got %s…%s %v, want %s…%s", tc.query, first.Format(dateLayout), last.Format(dateLayout), err, tc.first, tc.last)
		}
	}
	for _, bad := range []string{"from=2026-02-02&to=2026-02-01", "from=Feb", "to=2026-02-30"} {
		if _, _, err := dateWindow(query(t, bad), now, tokyo); err == nil {
			t.Errorf("%q: parsed, want refused", bad)
		}
	}
}

func TestGraphStatsYearAndTrendBucket(t *testing.T) {
	now := time.Date(2026, 7, 1, 0, 0, 0, 0, time.UTC)
	if y, err := graphStatsYear(query(t, ""), now); y != 2026 || err != nil {
		t.Errorf("default year: %d %v", y, err)
	}
	if y, err := graphStatsYear(query(t, "year=2024"), now); y != 2024 || err != nil {
		t.Errorf("year=2024: %d %v", y, err)
	}
	for _, bad := range []string{"year=0", "year=twenty"} {
		if _, err := graphStatsYear(query(t, bad), now); err == nil {
			t.Errorf("%s: parsed, want refused", bad)
		}
	}
	for raw, want := range map[string]string{"": "week", "bucket=week": "week", "bucket=month": "month", "bucket=day": ""} {
		got, err := trendBucket(query(t, raw))
		if got != want || (err != nil) != (want == "") {
			t.Errorf("%q: got %q %v, want %q", raw, got, err, want)
		}
	}
}

func TestPointSpeeds(t *testing.T) {
	// About 111 m a step north, ten seconds apart, then a step in the same second.
	lons := []float64{0, 0, 0, 0}
	lats := []float64{0, 0.001, 0.002, 0.003}
	ms := []float64{100, 110, 120, 120.9}
	got := pointSpeeds(lons, lats, ms)
	if math.Abs(got[1]-11.1) > 0.1 || got[0] != got[1] || got[3] != 0 {
		t.Fatalf("got %v, want ~11.1 m/s, the first copying the second, 0 across no time", got)
	}
	if got := pointSpeeds([]float64{1}, []float64{1}, []float64{1}); len(got) != 1 || got[0] != 0 {
		t.Fatalf("one point: %v", got)
	}
}
