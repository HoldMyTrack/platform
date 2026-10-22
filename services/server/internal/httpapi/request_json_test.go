package httpapi

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

func TestDecodeJSONRefusesUndeclaredFields(t *testing.T) {
	type inner struct {
		A int `json:"a"`
	}
	type body struct {
		Name  string  `json:"name"`
		Items []inner `json:"items"`
	}
	for in, want := range map[string]string{
		`{"name":"x","items":[{"a":1}]}`: "",
		`{"nmae":"x"}`:                   `unknown field "nmae"`,
		`{"items":[{"b":1}]}`:            `unknown field "b"`,
		`{"name":1}`:                     "invalid",
		`{`:                              "invalid",
	} {
		var v body
		err := decodeJSON(strings.NewReader(in), &v)
		got := ""
		if err != nil {
			got = bodyError(err, "invalid")
		}
		if got != want {
			t.Errorf("%s: got %q, want %q", in, got, want)
		}
	}
}

func TestUnknownField(t *testing.T) {
	var body map[string]json.RawMessage
	if err := json.Unmarshal([]byte(`{"route_at":"x","zeta":1,"alpha":2}`), &body); err != nil {
		t.Fatal(err)
	}
	if got, ok := unknownField(body, "caption", "route_at"); !ok || got != `unknown field "alpha"` {
		t.Errorf("got %q %v, want the first unknown key, sorted", got, ok)
	}
	if _, ok := unknownField(body, "route_at", "zeta", "alpha"); ok {
		t.Error("every key known, but one reported")
	}
}

func TestMisspelledRequestFieldIsRefused(t *testing.T) {
	d := newDBTest(t)
	me := d.newAccount(false)
	rec := d.do(me, "POST", "/v1/private-locations", map[string]any{"lon": 10.0, "lat": 50.0, "radius": 200})
	if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), `unknown field \"radius\"`) {
		t.Fatalf("status %d %s, want 400 naming the field", rec.Code, rec.Body)
	}
}
