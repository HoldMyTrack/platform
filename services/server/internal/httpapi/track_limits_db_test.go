package httpapi

import (
	"net/http"
	"strings"
	"testing"
)

// A track's name, type and description are limited in characters, not bytes (SPEC FR-5.5):
// a Cyrillic name of the full length, two bytes a letter, is accepted, and one letter more isn't.
func TestTrackEditLimitsCountCharacters(t *testing.T) {
	d := newDBTestWithS3(t, newMemS3())
	me := d.newAccount(false)
	id := d.ingestNorth(me, "walk.gpx", 10.0)

	for _, tc := range []struct {
		field string
		max   int
	}{
		{"name", maxTrackNameLen},
		{"track_type", maxTrackTypeLen},
		{"description", maxTrackDescriptionLen},
	} {
		// The edit sends every field; only the one under test is long.
		body := func(v string) map[string]any {
			b := map[string]any{"track_type": "walking", "name": "Walk", "description": ""}
			b[tc.field] = v
			return b
		}
		full := strings.Repeat("ж", tc.max)
		if rec := d.do(me, "PATCH", "/v2/tracks/"+id, body(full)); rec.Code != http.StatusOK {
			t.Errorf("%s of %d Cyrillic letters: %d %s, want 200", tc.field, tc.max, rec.Code, rec.Body)
		}
		if rec := d.do(me, "PATCH", "/v2/tracks/"+id, body(full+"ж")); rec.Code != http.StatusBadRequest {
			t.Errorf("%s of %d Cyrillic letters: %d, want 400", tc.field, tc.max+1, rec.Code)
		}
	}
}
