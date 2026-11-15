package stats

import (
	"fmt"
	"maps"
	"testing"
	"time"
)

func TestDayDue(t *testing.T) {
	now := time.Date(2026, 10, 14, 0, 30, 0, 0, time.UTC)
	yesterday := time.Date(2026, 10, 13, 0, 0, 0, 0, time.UTC)
	day := func(y int, m time.Month, d int) *time.Time { v := time.Date(y, m, d, 0, 0, 0, 0, time.UTC); return &v }
	for _, tc := range []struct {
		name string
		last *time.Time
		now  time.Time
		due  bool
	}{
		{"nothing taken yet", nil, now, true},
		{"yesterday taken", day(2026, 10, 13), now, false},
		{"yesterday taken, late in the day", day(2026, 10, 13), now.Add(23 * time.Hour), false},
		{"the day before taken", day(2026, 10, 12), now, true},
		{"days missed", day(2026, 10, 1), now, true},
		{"now in another zone", day(2026, 10, 13), now.In(time.FixedZone("UTC-5", -5*3600)), false},
	} {
		got, due := dayDue(tc.last, tc.now)
		if !got.Equal(yesterday) || due != tc.due {
			t.Errorf("%s: got %v %v, want %v %v", tc.name, got, due, yesterday, tc.due)
		}
	}
}

func TestFoldSmallGroups(t *testing.T) {
	ids := func(n int, prefix string) []string {
		out := make([]string, n)
		for i := range out {
			out[i] = fmt.Sprintf("%s%d", prefix, i)
		}
		return out
	}
	for _, tc := range []struct {
		name     string
		groups   map[string]float64
		accounts map[string]float64
		members  map[string][]string
		want     map[string]float64
	}{
		{"a group of 4 alone is left out", map[string]float64{"de": 9}, map[string]float64{"de": 4}, map[string][]string{"de": ids(4, "d")}, map[string]float64{}},
		{
			"a group of 4 takes the smallest kept group with it",
			map[string]float64{"de": 9, "fr": 70, "us": 40},
			map[string]float64{"de": 4, "fr": 7, "us": 40},
			map[string][]string{"de": ids(4, "d")},
			map[string]float64{"other": 79, "us": 40},
		},
		{"a group of 5 stays", map[string]float64{"de": 9}, map[string]float64{"de": 5}, nil, map[string]float64{"de": 9}},
		{
			"small groups of different accounts add up into one other",
			map[string]float64{"de": 3, "fr": 2, "us": 40},
			map[string]float64{"de": 3, "fr": 2, "us": 40},
			map[string][]string{"de": ids(3, "d"), "fr": ids(2, "f")},
			map[string]float64{"other": 5, "us": 40},
		},
		{
			"one account in five small groups is one account",
			map[string]float64{"de": 1, "fr": 1, "it": 1, "es": 1, "pt": 1, "us": 40},
			map[string]float64{"de": 1, "fr": 1, "it": 1, "es": 1, "pt": 1, "us": 40},
			map[string][]string{"de": {"x"}, "fr": {"x"}, "it": {"x"}, "es": {"x"}, "pt": {"x"}},
			map[string]float64{"other": 45},
		},
		{"nothing to fold, no other", map[string]float64{"us": 7}, map[string]float64{"us": 7}, nil, map[string]float64{"us": 7}},
		{"value folds by accounts, not by itself", map[string]float64{"de": 300, "us": 1}, map[string]float64{"de": 2, "us": 9}, map[string][]string{"de": ids(2, "d")}, map[string]float64{"other": 301}},
	} {
		if got := foldSmallGroups(tc.groups, tc.accounts, tc.members, minGroupAccounts); !maps.Equal(got, tc.want) {
			t.Errorf("%s: got %v, want %v", tc.name, got, tc.want)
		}
	}
}

func TestKeyFor(t *testing.T) {
	for _, tc := range []struct{ prefix, group, want string }{
		{"accounts_by_country", "DE", "accounts_by_country.de"},
		{"accounts_by_country", "", "accounts_by_country.unset"},
		{"locale", "pt-BR", "locale.pt_br"},
		{"jobs", "render_fog.done", "jobs.render_fog.done"},
		{"jobs", "ingest.", "jobs.ingest.unset"},
		{"ingest_failed", "Bad File!", "ingest_failed.bad_file_"},
	} {
		if got := keyFor(tc.prefix, tc.group); got != tc.want {
			t.Errorf("keyFor(%q, %q) = %q, want %q", tc.prefix, tc.group, got, tc.want)
		}
	}
}
