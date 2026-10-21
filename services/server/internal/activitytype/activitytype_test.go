package activitytype

import (
	"testing"

	"github.com/HoldMyTrack/platform/services/server/internal/i18n"
)

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

func TestLabel(t *testing.T) {
	for _, tc := range []struct{ typ, lang, want string }{
		{"gravel_cycling", "en", "Gravel Cycling"},
		{"Walking", "en", "Walking"},
		{"walking", "ru", "Ходьба"},
		{"evening_commute", "en", "Evening Commute"},
		{"My ride", "ru", "My ride"},
		{"__x__", "en", "X"},
		{"вечерняя_прогулка", "en", "Вечерняя Прогулка"},
	} {
		if got := Label(tc.typ, tc.lang); got != tc.want {
			t.Errorf("Label(%q, %s) = %q, want %q", tc.typ, tc.lang, got, tc.want)
		}
	}
}

// Every catalog type has a label of its own in every language.
func TestCatalogLabels(t *testing.T) {
	for _, lang := range i18n.Supported {
		for _, typ := range Catalog {
			if _, ok := i18n.Raw(lang, "activity_type."+typ); !ok {
				t.Errorf("%s: no label for %q", lang, typ)
			}
		}
	}
}
