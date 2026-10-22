package httpapi

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

// A field a handler can't work without is refused when missing, not read as its zero value:
// a position of 0, 0, a time of year 1.
func TestMissingRequiredFieldsAreRefused(t *testing.T) {
	d := newDBTest(t)
	me := d.newAccount(false)
	point := func(fields string) map[string]any {
		return map[string]any{"source": "recorded", "activities": []any{map[string]any{
			"external_id": "00000000-0000-4000-8000-000000000001", "activity_type": "walking",
			"points": []json.RawMessage{json.RawMessage(fields)},
		}}}
	}
	for _, tc := range []struct {
		name, method, path string
		body               any
		want               string
	}{
		{"private location without lat", "POST", "/v1/private-locations", map[string]any{"lon": 10.0, "radius_m": 200}, "location_position"},
		{"private location without lon", "PATCH", "/v1/private-locations/00000000-0000-4000-8000-000000000000", map[string]any{"lat": 50.0, "radius_m": 200}, "location_position"},
		{"sync point without lat", "POST", "/v1/sync/activities", point(`{"lon": 1, "time": "2026-01-01T12:00:00Z"}`), `needs \"lat\"`},
		{"sync point without time", "POST", "/v1/sync/activities", point(`{"lat": 1, "lon": 1}`), `needs \"lat\"`},
		{"overlap span without end", "POST", "/v1/activities/overlaps", map[string]any{"spans": []any{map[string]any{"key": "a", "start": "2026-01-01T12:00:00Z"}}}, `needs \"start\" and \"end\"`},
		{"merge without ids", "POST", "/v1/activities/track-merge", map[string]any{}, `\"ids\" needs`},
		{"merge with no ids", "POST", "/v1/activities/track-merge", map[string]any{"ids": []string{}}, `\"ids\" needs`},
	} {
		rec := d.do(me, tc.method, tc.path, tc.body)
		if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), tc.want) {
			t.Errorf("%s: status %d %s, want 400 with %s", tc.name, rec.Code, strings.TrimSpace(rec.Body.String()), tc.want)
		}
	}
}
