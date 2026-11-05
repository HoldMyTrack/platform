package httpapi

import (
	"math"
	"sort"
)

// paceBandCount is how many bands a track's speeds split into (docs/SPEC.md FR-4.8), slowest 0.
// The layers document's band colors have one each (apps/web/src/map/bandsGroup.ts).
const paceBandCount = 5

// paceBand is a run of points in one band, by index into the track's points, end inclusive.
type paceBand struct {
	Band  int `json:"band"`
	Start int `json:"start"`
	End   int `json:"end"`
}

// A band's width and its least, as log ratios of speed (docs/SPEC.md FR-4.8).
const (
	paceBandSpreadWidths = 2.0
	paceBandMinWidth     = 0.10
)

// weightedMedian is the first value, in ascending order, by which half the weight has passed.
func weightedMedian(values, weights []float64) float64 {
	order := make([]int, len(values))
	total := 0.0
	for i := range order {
		order[i] = i
		total += weights[i]
	}
	sort.SliceStable(order, func(a, b int) bool { return values[order[a]] < values[order[b]] })
	passed := 0.0
	for _, i := range order {
		passed += weights[i]
		if passed >= total/2 {
			return values[i]
		}
	}
	return 0
}

// paceBands bands a track's speeds around its own typical pace, the distance-weighted median, by
// their log ratio to it, so that going 10% faster and 10% slower are as far from typical. The
// median ignores a GPS glitch that a scale over the track's slowest and fastest points would let
// flatten the rest, and the least width keeps a steady track's small changes in one band instead
// of stretching them across all five. distances has each point's from the point before it, 0
// for what mustn't weigh in, like a Cut's join.
//
// Point i's band is its own speed's, and its run starts at point i-1, so the stretch leading into
// a point is coloured by how fast it was covered and neighbouring runs share their boundary point.
// Android runs the same cases (testdata/pace-bands.json) for the Sync tab's candidates, which
// aren't on the server.
func paceBands(speeds, distances []float64) []paceBand {
	bands := []paceBand{}
	if len(speeds) < 2 {
		return bands
	}
	var weighed, weights []float64
	for i := 1; i < len(speeds); i++ {
		if speeds[i] > 0 && distances[i] > 0 {
			weighed = append(weighed, speeds[i])
			weights = append(weights, distances[i])
		}
	}
	typical, width := 0.0, paceBandMinWidth
	if len(weighed) > 0 {
		typical = weightedMedian(weighed, weights)
		offs := make([]float64, len(weighed))
		for i, v := range weighed {
			offs[i] = math.Abs(math.Log(v / typical))
		}
		width = math.Max(paceBandMinWidth, paceBandSpreadWidths*weightedMedian(offs, weights))
	}
	index := func(v float64) int {
		switch {
		case typical == 0:
			return paceBandCount / 2
		case v <= 0:
			return 0
		}
		return min(paceBandCount-1, max(0, int(math.Floor(math.Log(v/typical)/width+float64(paceBandCount)/2))))
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
