package httpapi

import "math"

// paceBandCount is how many bands a track's speeds split into (docs/SPEC.md FR-4.8), slowest 0.
// The layers document's band colors have one each (apps/web/src/map/bandsGroup.ts).
const paceBandCount = 5

// paceBand is a run of points in one band, by index into the track's points, end inclusive.
type paceBand struct {
	Band  int `json:"band"`
	Start int `json:"start"`
	End   int `json:"end"`
}

// paceBands splits a track's speeds, one per point, into equal bins over the track's own range,
// since where in a run someone was fastest is a question about that run. Point i's band is its own
// speed's, and its run starts at point i-1, so the stretch leading into a point is coloured by how
// fast it was covered and neighbouring runs share their boundary point. Android runs the same cases
// (testdata/pace-bands.json) for the Sync tab's candidates, which aren't on the server.
func paceBands(speeds []float64) []paceBand {
	bands := []paceBand{}
	if len(speeds) < 2 {
		return bands
	}
	lo, hi := speeds[0], speeds[0]
	for _, v := range speeds {
		lo, hi = math.Min(lo, v), math.Max(hi, v)
	}
	span := hi - lo
	if span == 0 {
		span = 1
	}
	index := func(v float64) int {
		return min(paceBandCount-1, max(0, int(math.Floor((v-lo)/span*paceBandCount))))
	}
	current, start := -1, 0
	for i := 1; i < len(speeds); i++ {
		band := index(speeds[i])
		if band == current {
			continue
		}
		if current != -1 && i-1 > start {
			bands = append(bands, paceBand{current, start, i - 1})
		}
		current, start = band, i-1
	}
	if len(speeds)-1 > start {
		bands = append(bands, paceBand{current, start, len(speeds) - 1})
	}
	return bands
}
