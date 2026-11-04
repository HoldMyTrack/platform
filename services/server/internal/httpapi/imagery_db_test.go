package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/HoldMyTrack/platform/services/server/internal/imagery"
	"github.com/HoldMyTrack/platform/services/server/internal/mapstyle"
)

// The worker's decision reaches both clients (docs/SPEC.md FR-4.14): paused, the style leaves the
// imagery out and GET /v1/map/imagery says so; offered again, both bring it back.
func TestImageryStatusPublished(t *testing.T) {
	d := newDBTest(t)
	ctx := context.Background()
	clean := func() { d.pool.Exec(context.Background(), `DELETE FROM imagery_status`) }
	clean()
	t.Cleanup(clean)
	d.srv.satellite = mapstyle.Satellite{Tiles: "https://imagery.example/{z}/{x}/{y}.jpg?key=k", TileSize: 512, MaxZoom: 18, Attribution: "© Imagery"}

	state := func() (styleHasImagery, endpoint bool) {
		t.Helper()
		d.srv.imagery = imageryCache{} // what the next minute would read
		var style struct {
			Sources map[string]json.RawMessage `json:"sources"`
		}
		d.decode(d.do(account{}, http.MethodGet, "/v1/map/style/light", nil), http.StatusOK, &style)
		var res imageryResponse
		d.decode(d.do(account{}, http.MethodGet, "/v1/map/imagery", nil), http.StatusOK, &res)
		_, has := style.Sources["satellite"]
		return has, res.Available
	}

	if style, ep := state(); !style || !ep {
		t.Fatalf("nothing decided yet: style %v, endpoint %v; want imagery offered", style, ep)
	}
	used, limit := int64(96000), int64(100000)
	if err := imagery.Save(ctx, d.pool, imagery.Status{Available: false, Reason: imagery.ReasonQuota, Used: &used, Limit: &limit, CheckedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	if style, ep := state(); style || ep {
		t.Fatalf("paused: style %v, endpoint %v; want no imagery", style, ep)
	}
	if err := imagery.Save(ctx, d.pool, imagery.Status{Available: true, CheckedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	if style, ep := state(); !style || !ep {
		t.Fatalf("offered again: style %v, endpoint %v; want imagery", style, ep)
	}

	// Without imagery configured, nothing is offered whatever is stored.
	d.srv.satellite = mapstyle.Satellite{}
	if style, ep := state(); style || ep {
		t.Fatalf("not configured: style %v, endpoint %v; want no imagery", style, ep)
	}
}
