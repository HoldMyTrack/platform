package httpapi

import (
	"fmt"
	"testing"
)

// A heat-points tile is empty at every zoom, whatever the account has stored: the route stays
// for installed Android builds until MIN_ANDROID_BUILD next goes up.
func TestHeatPointsTileIsEmpty(t *testing.T) {
	mem := newMemS3()
	d := newDBTestWithS3(t, mem)
	me := d.newAccount(false)
	mem.Put(fmt.Sprintf("heatmap/%s/14/4471/6119.png", me.id), []byte("counts"))

	for _, path := range []string{"5/8/11", "14/4471/6119", "15/8942/12238", "16/17884/24476"} {
		rec := d.do(me, "GET", "/tiles/v1/heat-points/"+path+".mvt", nil)
		if rec.Code != 200 {
			t.Fatalf("%s: status %d", path, rec.Code)
		}
		if got := rec.Header().Get("Content-Type"); got != "application/vnd.mapbox-vector-tile" {
			t.Errorf("%s: Content-Type %q", path, got)
		}
		if n := rec.Body.Len(); n != 0 {
			t.Errorf("%s: %d bytes, want an empty tile", path, n)
		}
	}
}
