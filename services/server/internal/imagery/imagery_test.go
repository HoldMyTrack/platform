package imagery

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

func n(v int64) *int64 { return &v }

func TestDecide(t *testing.T) {
	for _, tc := range []struct {
		name          string
		used, limit   *int64
		probeFailures int
		available     bool
		reason        string
	}{
		{"well under the limit", n(1366), n(100000), 0, true, ""},
		{"just under the share", n(94999), n(100000), 0, true, ""},
		{"at the share", n(95000), n(100000), 0, false, ReasonQuota},
		{"over the limit", n(120000), n(100000), 0, false, ReasonQuota},
		{"usage not read", nil, nil, 0, true, ""},
		{"no limit configured", n(500000), nil, 0, true, ""},
		{"one probe failure is a blip", n(10), n(100000), 1, true, ""},
		{"two probe failures in a row", n(10), n(100000), 2, false, ReasonProbe},
		{"the quota wins over the probe", n(99000), n(100000), 3, false, ReasonQuota},
		{"the probe alone, without usage", nil, nil, 2, false, ReasonProbe},
	} {
		t.Run(tc.name, func(t *testing.T) {
			available, reason := Decide(tc.used, tc.limit, tc.probeFailures)
			if available != tc.available || reason != tc.reason {
				t.Errorf("Decide = %v %q, want %v %q", available, reason, tc.available, tc.reason)
			}
		})
	}
}

// The answer production gave on 2026-11-04, one service with a day absent.
const usageAnswer = `{"since":"2026-10-29","until":"2026-11-28","legend":[{"item_id":"request.tile","label":"Tiles","description":null}],"datasets":[{"group_id":"request","item_id":"request.tile","data":[{"date":"2026-10-29","value":49},{"date":"2026-10-30","value":167},{"date":"2026-10-31","value":251},{"date":"2026-11-01","value":44},{"date":"2026-11-02","value":518},{"date":"2026-11-04","value":337}],"estimated_data":{"date":"2026-11-04","value":537}}]}`

func TestUsage(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Token secret" {
			http.Error(w, "no", http.StatusUnauthorized)
			return
		}
		w.Write([]byte(usageAnswer))
	}))
	defer srv.Close()
	got, err := Usage(context.Background(), srv.Client(), srv.URL, "secret")
	if err != nil {
		t.Fatal(err)
	}
	// The days' values, not the day's estimate.
	if got != 1366 {
		t.Errorf("Usage = %d, want 1366", got)
	}
	if _, err := Usage(context.Background(), srv.Client(), srv.URL, "wrong"); err == nil {
		t.Error("a refused read reported no error")
	}
}

func TestProbe(t *testing.T) {
	var path, referer string
	status := http.StatusOK
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path, referer = r.URL.Path, r.Header.Get("Referer")
		w.WriteHeader(status)
	}))
	defer srv.Close()
	tiles := srv.URL + "/tiles/{z}/{x}/{y}.jpg?key=k"
	if err := Probe(context.Background(), srv.Client(), tiles, "https://holdmytrack.com/"); err != nil {
		t.Fatal(err)
	}
	if path != "/tiles/0/0/0.jpg" || referer != "https://holdmytrack.com/" {
		t.Errorf("probed %q with referer %q", path, referer)
	}
	status = http.StatusForbidden
	if err := Probe(context.Background(), srv.Client(), tiles, "https://holdmytrack.com/"); err == nil {
		t.Error("a refused tile reported no error")
	}
}
