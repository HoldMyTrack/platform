package httpapi

import (
	"testing"

	"github.com/getkin/kin-openapi/openapi3"
)

// The limits the contract declares are the ones the handlers enforce, so a client reading
// them (the web's constants, checked against the same contract) refuses what the server would.
func TestContractLimitsMatchTheHandlers(t *testing.T) {
	doc, err := newContractLoader().LoadFromFile(contractPath)
	if err != nil {
		t.Fatal(err)
	}
	body := func(method, path string) *openapi3.Schema {
		t.Helper()
		op := doc.Paths.Find(path).GetOperation(method)
		if op == nil || op.RequestBody == nil {
			t.Fatalf("%s %s: no request body in the contract", method, path)
		}
		for _, media := range op.RequestBody.Value.Content {
			return media.Schema.Value
		}
		t.Fatalf("%s %s: no request schema", method, path)
		return nil
	}
	property := func(schema *openapi3.Schema, name string) *openapi3.Schema {
		t.Helper()
		p := schema.Properties[name]
		if p == nil {
			t.Fatalf("no property %q", name)
		}
		return p.Value
	}
	maxLength := func(s *openapi3.Schema) int {
		if s.MaxLength == nil {
			return -1
		}
		return int(*s.MaxLength)
	}
	number := func(f *float64) int {
		if f == nil {
			return -1
		}
		return int(*f)
	}

	activity := body("PATCH", "/activities/{id}")
	story := body("POST", "/stories")
	location := body("POST", "/private-locations")
	for _, tc := range []struct {
		name      string
		got, want int
	}{
		{"activity_type", maxLength(property(activity, "activity_type")), maxActivityTypeLen},
		{"activity name", maxLength(property(activity, "name")), maxActivityNameLen},
		{"activity description", maxLength(property(activity, "description")), maxActivityDescriptionLen},
		{"Story name", maxLength(property(story, "name")), maxStoryNameLen},
		{"Story description", maxLength(property(story, "description")), maxStoryDescriptionLen},
		{"photo caption (upload)", maxLength(property(body("POST", "/photos"), "caption")), maxPhotoCaptionLen},
		{"photo caption (edit)", maxLength(property(body("PATCH", "/photos/{id}"), "caption")), maxPhotoCaptionLen},
		{"Private location name", maxLength(property(location, "name")), maxPrivateLocationNameLen},
		{"Private location minimum radius", number(property(location, "radius_m").Min), minPrivateLocationRadiusM},
		{"Private location maximum radius", number(property(location, "radius_m").Max), maxPrivateLocationRadiusM},
	} {
		if tc.got != tc.want {
			t.Errorf("%s: the contract says %d, the handler %d", tc.name, tc.got, tc.want)
		}
	}
}
