// Package activitytype says what the clients show for an activity type (docs/SPEC.md FR-5.1):
// its label in the request's language, and which kind of moving it is, for a row's icon and
// whether its card reads pace or speed. Types
// are free text, so a kind comes from the words in one ("gravel_cycling" is on wheels,
// "trail_running" on foot), never from a fixed list. Display only: nothing here changes an
// activity (ADR-0039).
package activitytype

import (
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/HoldMyTrack/platform/services/server/internal/i18n"
)

// Kind is what kind of moving a type is.
type Kind string

const (
	// Foot reads as a pace, minutes per km or mile; every other kind as a speed.
	Foot   Kind = "foot"
	Wheels Kind = "wheels"
	Motor  Kind = "motor"
	// Solowheel and EScooter are on wheels with an icon of their own.
	Solowheel Kind = "solowheel"
	EScooter  Kind = "e_scooter"
	// Other is paddling, skiing, an untyped activity: speed, the safer reading.
	Other Kind = "other"
)

// kindWords is matched in order, case-insensitively, anywhere in the type: the first kind with
// a word in it wins.
var kindWords = []struct {
	kind  Kind
	words []string
}{
	{Solowheel, []string{"solowheel", "monowheel"}},
	{EScooter, []string{"e_scooter", "escooter"}},
	{Motor, []string{"driv", "motor", "car"}},
	{Wheels, []string{"cycl", "bik", "skat", "wheel", "scoot", "board"}},
	{Foot, []string{"walk", "hik", "run", "jog", "trek", "stroll", "march"}},
}

// KindOf is the kind of activityType.
func KindOf(activityType string) Kind {
	t := strings.ToLower(activityType)
	for _, k := range kindWords {
		for _, w := range k.words {
			if strings.Contains(t, w) {
				return k.kind
			}
		}
	}
	return Other
}

// Catalog is the types the Type picker can suggest beyond an account's own: the ones the
// parsers and the phone's Health Connect read produce most, and the recording presets.
var Catalog = []string{
	"alpine_skiing", "biking", "biking_stationary", "bus", "cross_country_skiing", "cycling", "driving",
	"e_biking", "ferry", "flying", "generic", "golf", "gravel_cycling", "hiking", "horseback_riding",
	"ice_skating", "inline_skating", "kayaking", "motorcycling", "mountain_biking", "other_workout",
	"paddling", "road_cycling", "rock_climbing", "rowing", "rowing_machine", "running",
	"running_treadmill", "sailing", "skating", "skiing", "snowboarding", "stand_up_paddleboarding",
	"subway", "surfing", "swimming", "swimming_open_water", "swimming_pool", "tennis", "trail_running",
	"train", "tram", "unknown", "walk", "walking", "yoga",
}

// Info is what a client shows for one type.
type Info struct {
	Kind  Kind   `json:"kind"`
	Label string `json:"label"`
}

// Describe is Info for each of types in lang, keyed by the type as given.
func Describe(types []string, lang string) map[string]Info {
	out := make(map[string]Info, len(types))
	for _, t := range types {
		out[t] = Info{Kind: KindOf(t), Label: Label(t, lang)}
	}
	return out
}

// Label is activityType's name in lang: the catalog's (`activity_type.*` in the locales),
// matched case-insensitively, else the type itself, spaced out from snake_case and title-cased.
// Never a remapping of what the value means.
func Label(activityType, lang string) string {
	if msg, ok := i18n.Raw(lang, "activity_type."+strings.ToLower(activityType)); ok {
		return msg
	}
	if msg, ok := i18n.Raw(i18n.Default, "activity_type."+strings.ToLower(activityType)); ok {
		return msg
	}
	words := strings.Split(activityType, "_")
	out := words[:0]
	for _, w := range words {
		if w != "" {
			r, size := utf8.DecodeRuneInString(w)
			out = append(out, string(unicode.ToUpper(r))+w[size:])
		}
	}
	return strings.Join(out, " ")
}
