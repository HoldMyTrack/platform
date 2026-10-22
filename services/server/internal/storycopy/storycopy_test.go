package storycopy

import "testing"

func TestPlan(t *testing.T) {
	for _, tc := range []struct {
		name    string
		pending []bool
		ready   int
		retry   bool
	}{
		{"nothing to copy", nil, 0, false},
		{"all ready", []bool{false, false}, 2, false},
		{"some mid-edit", []bool{false, true, false}, 2, true},
		{"all mid-edit", []bool{true, true}, 0, true},
	} {
		sources := make([]source, len(tc.pending))
		for i, p := range tc.pending {
			sources[i].pending = p
		}
		ready, retry := plan(sources)
		if ready != tc.ready || retry != tc.retry {
			t.Errorf("%s: got %d %v, want %d %v", tc.name, ready, retry, tc.ready, tc.retry)
		}
	}
}

func TestSourceDetail(t *testing.T) {
	name, blank := "Morning loop", ""
	for _, tc := range []struct {
		name *string
		want string
	}{{&name, "Morning loop.gpx"}, {&blank, "running.gpx"}, {nil, "running.gpx"}} {
		if got := sourceDetail(source{activityType: "running", name: tc.name}); got != tc.want {
			t.Errorf("name %v: got %q, want %q", tc.name, got, tc.want)
		}
	}
}
