package statscard

import (
	"reflect"
	"testing"

	"github.com/HoldMyTrack/platform/services/server/internal/i18n"
)

func f(v float64) *float64 { return &v }
func s(v int32) *int32     { return &v }

func hike() Activity {
	return Activity{Type: "hiking", DistanceMeters: f(13197), MovingSeconds: s(13260), ElevationGainM: f(591)}
}

func TestValues(t *testing.T) {
	en, ru := i18n.Get("en"), i18n.Get("ru")
	ride := Activity{Type: "cycling", DistanceMeters: f(39429), MovingSeconds: s(7500), ElevationGainM: f(341)}
	flat := Activity{Type: "walking", DistanceMeters: f(1770), MovingSeconds: s(1620), ElevationGainM: f(0)}
	noGain := Activity{Type: "walking", DistanceMeters: f(1770), MovingSeconds: s(1620)}
	private := Activity{Type: "walking", Private: true, DistanceMeters: f(1000)}

	six := []Activity{hike(), ride, flat, hike(), ride, flat}
	for _, tc := range []struct {
		name     string
		acts     []Activity
		l        *i18n.Localizer
		imperial bool
		want     Card
	}{
		{"one imperial", []Activity{hike()}, en, true, Card{Lines: []string{"Hiking · 8.2 mi · 3h 41m · 1,939 ft"}}},
		{"one metric", []Activity{hike()}, en, false, Card{Lines: []string{"Hiking · 13.2 km · 3h 41m · 591 m"}}},
		{"no elevation", []Activity{flat}, en, false, Card{Lines: []string{"Walking · 1.8 km · 27m"}}},
		{"no gain recorded", []Activity{noGain}, en, false, Card{Lines: []string{"Walking · 1.8 km · 27m"}}},
		{"private", []Activity{private}, en, false, Card{Lines: []string{"Walking"}}},
		{"private in totals", []Activity{hike(), private}, en, false, Card{
			Lines:  []string{"Hiking · 13.2 km · 3h 41m · 591 m", "Walking"},
			Totals: "2 activities · 13 km · 3h 41m · 591 m",
		}},
		{"five", six[:5], en, false, Card{
			Lines:  []string{"Hiking · 13.2 km · 3h 41m · 591 m", "Cycling · 39.4 km · 2h 5m · 341 m", "Walking · 1.8 km · 27m", "Hiking · 13.2 km · 3h 41m · 591 m", "Cycling · 39.4 km · 2h 5m · 341 m"},
			Totals: "5 activities · 107 km · 11h 59m · 1,864 m",
		}},
		{"six", six, en, false, Card{
			Lines:  []string{"Hiking · 13.2 km · 3h 41m · 591 m", "Cycling · 39.4 km · 2h 5m · 341 m", "Walking · 1.8 km · 27m", "Hiking · 13.2 km · 3h 41m · 591 m", "Cycling · 39.4 km · 2h 5m · 341 m"},
			More:   "+ 1 more",
			Totals: "6 activities · 109 km · 12h 26m · 1,864 m",
		}},
		{"russian", []Activity{hike(), flat}, ru, false, Card{
			Lines:  []string{"Поход · 13,2 км · 3 ч 41 мин · 591 м", "Ходьба · 1,8 км · 27 мин"},
			Totals: "2 занятия · 15 км · 4 ч 8 мин · 591 м",
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := Values(tc.acts, tc.l, tc.imperial); !reflect.DeepEqual(got, tc.want) {
				t.Errorf("got  %#v\nwant %#v", got, tc.want)
			}
		})
	}
}
