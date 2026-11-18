package ingest

import (
	"encoding/json"
	"testing"
)

func TestRenameSyncPayloadType(t *testing.T) {
	out, changed, err := renameSyncPayloadType([]byte(`{"activity_type":"walking","points":[{"lat":1,"lon":2,"time":"2026-05-01T10:00:00Z"}],"name":"Walk"}`))
	if err != nil || !changed {
		t.Fatalf("changed %v, err %v", changed, err)
	}
	var got map[string]any
	if err := json.Unmarshal(out, &got); err != nil {
		t.Fatal(err)
	}
	if got["track_type"] != "walking" || got["activity_type"] != nil || got["name"] != "Walk" || len(got["points"].([]any)) != 1 {
		t.Errorf("got %s", out)
	}
	for _, in := range []string{`{"track_type":"walking","points":[]}`, `{"points":[]}`} {
		if out, changed, err := renameSyncPayloadType([]byte(in)); err != nil || changed || string(out) != in {
			t.Errorf("%s: changed %v, err %v, out %s", in, changed, err, out)
		}
	}
	if _, _, err := renameSyncPayloadType([]byte(`not json`)); err == nil {
		t.Error("not JSON: no error")
	}
}
