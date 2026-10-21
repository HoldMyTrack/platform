package activitytype

import "testing"

func TestKindOf(t *testing.T) {
	for typ, want := range map[string]Kind{
		"walking":           Foot,
		"trail_running":     Foot,
		"Hiking":            Foot,
		"cycling":           Wheels,
		"gravel_cycling":    Wheels,
		"e_biking":          Wheels,
		"inline_skating":    Wheels,
		"driving":           Motor,
		"motorcycling":      Motor,
		"Solowheel":         Solowheel,
		"monowheel_commute": Solowheel,
		"e_scooter_commute": EScooter,
		"kayaking":          Other,
		"unknown":           Other,
		"":                  Other,
	} {
		if got := KindOf(typ); got != want {
			t.Errorf("KindOf(%q) = %q, want %q", typ, got, want)
		}
	}
}
