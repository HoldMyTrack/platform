package ingest

// Covers docs/SPEC.md FR-5.17 (splitting and merging).

import (
	"testing"
	"time"
)

func ms(v int64) *int64 { return &v }

func TestSplitRangeApply(t *testing.T) {
	points, at := editFixture()
	got := SplitRange{From: ms(at[3]), To: ms(at[6])}.Apply(points, nil)
	if want := []int{3, 4, 5, 6}; !equalInts(survivors(got, at[0]), want) {
		t.Fatalf("piece kept %v, want %v", survivors(got, at[0]), want)
	}
	if got := (SplitRange{}).Apply(points, nil); len(got) != len(points) {
		t.Fatalf("whole range kept %d of %d points", len(got), len(points))
	}
	if got := (SplitRange{To: ms(at[1])}).Apply(points, nil); !equalInts(survivors(got, at[0]), []int{0, 1}) {
		t.Fatalf("open start kept %v", survivors(got, at[0]))
	}
}

// A split made inside a Private location leaves the new end there; Apply clips it off again.
func TestSplitRangeApplyClipsNewEnd(t *testing.T) {
	points, at := editFixture()
	// A zone around points 4–5 only: the original track's ends are outside it.
	zones := []Zone{{Lat: points[4].Lat + 0.00005, Lon: points[4].Lon, RadiusM: 8}}
	got := SplitRange{To: ms(at[5])}.Apply(points, zones)
	if last := got[len(got)-1]; zones[0].contains(last) || last.Time.UnixMilli() >= at[4] {
		t.Fatalf("piece still ends inside the zone, at +%dms", last.Time.UnixMilli()-at[0])
	}
}

func TestCheckSplit(t *testing.T) {
	points, at := editFixture()
	for _, c := range []struct {
		at int64
		ok bool
	}{
		{at[1], true}, {at[8], true}, {at[5], true},
		{at[0], false}, {at[9], false}, {at[0] + 500, false},
	} {
		if err := CheckSplit(points, nil, nil, c.at); (err == nil) != c.ok {
			t.Errorf("split at +%dms: err = %v, want ok=%v", c.at-at[0], err, c.ok)
		}
	}
	// The edit counts: with points 0–2 chopped away, point 4 leaves one side only 3 and 4.
	chop := &TrackEdit{Keep: &[2]int64{at[3], at[9]}}
	if err := CheckSplit(points, nil, chop, at[4]); err != nil {
		t.Errorf("split at 4 after a chop: %v", err)
	}
	if err := CheckSplit(points, nil, chop, at[3]); err != ErrSplitTooClose {
		t.Errorf("split at the chopped track's first point: %v, want ErrSplitTooClose", err)
	}
}

// A walk ending at home, inside a Private location, with one stray fix just outside it as its
// last point: the first clip keeps every point, since the track doesn't end inside. Once the
// stray fix is deleted, the saved track stops short of the circle — but the editor still shows
// the points inside, and a split among them would leave one part with nothing to show.
func TestCheckSplitInsidePrivateLocation(t *testing.T) {
	points, at := editFixture()
	stray := pt(points[0].Lat, points[0].Lon+0.001, points[9].Time.Add(time.Second))
	points = append(points, stray)
	zones := []Zone{{Lat: points[8].Lat, Lon: points[8].Lon, RadiusM: 30}} // points 6–9 inside
	dropStray := &TrackEdit{Drop: []int64{stray.Time.UnixMilli()}}
	if err := CheckSplit(points, zones, dropStray, at[7]); err != ErrSplitHidden {
		t.Errorf("split inside the location: %v, want ErrSplitHidden", err)
	}
	// Well before the location, the later part keeps the points up to a radius short of it.
	if err := CheckSplit(points, zones, dropStray, at[1]); err != nil {
		t.Errorf("split before the location: %v", err)
	}
	// Without the edit the later part keeps the stray fix, and with it a track.
	if err := CheckSplit(points, zones, nil, at[7]); err != nil {
		t.Errorf("split inside the location, stray fix kept: %v", err)
	}
}
