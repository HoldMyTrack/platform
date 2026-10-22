package db

import "testing"

func TestBaselineStep(t *testing.T) {
	for _, tc := range []struct {
		name     string
		recorded []string
		want     baselineAction
	}{
		{"a new database runs it", nil, baselineRun},
		{"one that ran it skips it", []string{baselineFile, "0046_next.sql"}, baselineRun},
		{"one the replaced migrations built records it", []string{"0001_users_and_auth.sql", baselineCovers}, baselineRecord},
		{"one partway through them is refused", []string{"0001_users_and_auth.sql", "0030_activity_tile_mask_data.sql"}, baselineRefuse},
	} {
		recorded := map[string]bool{}
		for _, n := range tc.recorded {
			recorded[n] = true
		}
		if got := baselineStep(recorded); got != tc.want {
			t.Errorf("%s: got %d, want %d", tc.name, got, tc.want)
		}
	}
}
