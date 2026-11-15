package httpapi

import (
	"net/url"
	"testing"
	"time"
)

// A window reaches back to 1970, where the Android profile asks from, and up to two years ahead;
// not to the year 1, since every bucket is a row.
func TestDateWindowSpan(t *testing.T) {
	now := time.Date(2026, 11, 15, 12, 0, 0, 0, time.UTC)
	for q, ok := range map[string]bool{
		"from=1970-01-01&to=2026-12-31": true,
		"from=2025-01-01&to=2028-11-15": true,
		"from=0001-01-01&to=9999-12-31": false,
		"from=1969-12-31&to=2026-11-15": false,
		"from=2025-01-01&to=2028-11-16": false,
	} {
		v, _ := url.ParseQuery(q)
		if _, _, err := dateWindow(v, now, time.UTC); (err == nil) != ok {
			t.Errorf("%s: err %v, want ok=%v", q, err, ok)
		}
	}
}
