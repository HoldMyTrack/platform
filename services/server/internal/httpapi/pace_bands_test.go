package httpapi

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"
)

// TestPaceBands runs the cases Android runs too (testdata/pace-bands.json), reached from this
// package the way the web's shared cases are: Makefile's test-go mounts testdata at /testdata.
func TestPaceBands(t *testing.T) {
	b, err := os.ReadFile("../../../../testdata/pace-bands.json")
	if err != nil {
		t.Fatal(err)
	}
	var file struct {
		Cases []struct {
			Name  string `json:"name"`
			Input struct {
				Speeds []float64 `json:"speeds"`
			} `json:"input"`
			Expected []paceBand `json:"expected"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(b, &file); err != nil {
		t.Fatal(err)
	}
	if len(file.Cases) == 0 {
		t.Fatal("no cases")
	}
	for _, c := range file.Cases {
		if got := paceBands(c.Input.Speeds); !reflect.DeepEqual(got, c.Expected) {
			t.Errorf("%s: %v, want %v", c.Name, got, c.Expected)
		}
	}
}
