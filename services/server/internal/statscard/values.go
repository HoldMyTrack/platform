// Package statscard draws the stats card a map image export carries (docs/SPEC.md FR-4.7,
// docs/IMPLEMENTATION.md §4.3.3): the checked activities' numbers, formatted here so every
// client shows the same text, on a translucent panel the client lays over its own map image.
//
// Values turns rows into the card's text, Layout places that text for an image size, and Render
// draws the layout as a PNG. Each step is a function of its inputs alone.
package statscard

import (
	"strings"

	"github.com/HoldMyTrack/platform/services/server/internal/activitytype"
	"github.com/HoldMyTrack/platform/services/server/internal/i18n"
	"github.com/HoldMyTrack/platform/services/server/internal/web"
)

// MaxLines is how many activities the card lists before "+ N more".
const MaxLines = 5

// Activity is one checked activity, as the Activities panel row has it.
type Activity struct {
	Type           string
	DistanceMeters *float64
	// MovingSeconds is the row's time: moving time, else the elapsed duration.
	MovingSeconds  *int32
	ElevationGainM *float64
	// Private is an activity entirely inside Private locations: the card shows its type only.
	Private bool
}

// Card is the card's text, top to bottom. More and Totals are "" when absent.
type Card struct {
	Lines  []string
	More   string
	Totals string
}

const sep = " · "

// Values is the card for acts, newest first: a line for each of the first MaxLines, "+ N more"
// for the rest, and with more than one, a totals line over all of them.
func Values(acts []Activity, l *i18n.Localizer, imperial bool) Card {
	var c Card
	var dist, elev float64
	var secs int64
	for i, a := range acts {
		if !a.Private {
			if a.DistanceMeters != nil {
				dist += *a.DistanceMeters
			}
			if a.MovingSeconds != nil {
				secs += int64(*a.MovingSeconds)
			}
			if a.ElevationGainM != nil {
				elev += *a.ElevationGainM
			}
		}
		if i < MaxLines {
			c.Lines = append(c.Lines, line(a, l, imperial))
		}
	}
	if n := len(acts) - MaxLines; n > 0 {
		c.More = l.T("stats_card.more", "n", n)
	}
	if len(acts) > 1 {
		parts := []string{l.N("count.activities", int64(len(acts)))}
		if dist > 0 {
			parts = append(parts, web.FormatTotalDistance(l, dist, imperial))
		}
		if secs > 0 {
			parts = append(parts, web.FormatDuration(l, secs))
		}
		if web.FormatElevation(l, elev, imperial) != web.FormatElevation(l, 0, imperial) {
			parts = append(parts, web.FormatElevation(l, elev, imperial))
		}
		c.Totals = strings.Join(parts, sep)
	}
	return c
}

// line is one activity's: type · distance · time · elevation gain, each left out when unknown,
// and the gain also when it rounds to 0, as on a GPS-only recording.
func line(a Activity, l *i18n.Localizer, imperial bool) string {
	parts := []string{activitytype.Label(a.Type, l.Lang())}
	if a.Private {
		return parts[0]
	}
	if a.DistanceMeters != nil {
		parts = append(parts, web.FormatDistance(l, *a.DistanceMeters, imperial))
	}
	if a.MovingSeconds != nil {
		parts = append(parts, web.FormatDuration(l, int64(*a.MovingSeconds)))
	}
	if a.ElevationGainM != nil {
		if e := web.FormatElevation(l, *a.ElevationGainM, imperial); e != web.FormatElevation(l, 0, imperial) {
			parts = append(parts, e)
		}
	}
	return strings.Join(parts, sep)
}
