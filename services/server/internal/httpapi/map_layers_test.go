package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/HoldMyTrack/platform/services/server/internal/fog"
	"github.com/HoldMyTrack/platform/services/server/internal/mapstyle"
)

// TestMapLayers: the layers document is the account's, at its tile version, revalidated with a
// 304 until the version moves, and refused without a session.
func TestMapLayers(t *testing.T) {
	d := newDBTest(t)
	me := d.newAccount(false)

	if rec := d.do(account{}, "GET", "/v1/map/layers?flavor=light", nil); rec.Code != http.StatusUnauthorized {
		t.Fatalf("signed out: status %d, want 401", rec.Code)
	}
	if rec := d.do(me, "GET", "/v1/map/layers?flavor=neon", nil); rec.Code != http.StatusNotFound {
		t.Fatalf("unknown flavor: status %d, want 404", rec.Code)
	}

	var doc struct {
		StyleBuild  string `json:"styleBuild"`
		Flavor      string `json:"flavor"`
		TileVersion string `json:"tileVersion"`
		Groups      []struct {
			ID      string `json:"id"`
			Sources map[string]struct {
				Tiles string `json:"tiles"`
			} `json:"sources"`
		} `json:"groups"`
	}
	rec := d.do(me, "GET", "/v1/map/layers?flavor=dark", nil)
	d.decode(rec, http.StatusOK, &doc)
	want := fog.TileVersion(me.id, 0)
	if doc.TileVersion != want || doc.Flavor != "dark" || doc.StyleBuild != mapstyle.StyleBuild() {
		t.Fatalf("doc = %s/%s/%s, want %s/dark/%s", doc.TileVersion, doc.Flavor, doc.StyleBuild, want, mapstyle.StyleBuild())
	}
	if strings.Contains(rec.Body.String(), "__HOLDMYTRACK") {
		t.Error("a placeholder survived")
	}
	for _, g := range doc.Groups {
		for id, s := range g.Sources {
			if s.Tiles != "" && !strings.HasSuffix(s.Tiles, "?cv="+want) {
				t.Errorf("%s/%s: tiles %q don't carry the tile version", g.ID, id, s.Tiles)
			}
		}
	}
	if got := rec.Header().Get("Cache-Control"); got != "private, no-cache" {
		t.Errorf("Cache-Control = %q", got)
	}

	etag := rec.Header().Get("ETag")
	revalidate := func() int {
		req := httptest.NewRequest("GET", "/v1/map/layers?flavor=dark", nil)
		req.Header.Set("Authorization", bearerPrefix+me.session)
		req.Header.Set("If-None-Match", etag)
		rec := httptest.NewRecorder()
		d.srv.ServeHTTP(rec, req)
		checkContract(t, req, nil, rec)
		return rec.Code
	}
	if code := revalidate(); code != http.StatusNotModified {
		t.Fatalf("revalidated: status %d, want 304", code)
	}
	if _, err := d.pool.Exec(context.Background(), `UPDATE users SET map_version = map_version + 1 WHERE id = $1`, me.id); err != nil {
		t.Fatal(err)
	}
	if code := revalidate(); code != http.StatusOK {
		t.Fatalf("after a tile version change: status %d, want 200", code)
	}
}

// TestStyleCarriesNoAccountData: the shared style holds no layer the layers document draws, and
// both documents name the same build.
func TestStyleCarriesNoAccountData(t *testing.T) {
	for _, flavor := range mapstyle.Flavors() {
		style, err := mapstyle.Document(flavor, "en", "https://cdn.example.com", mapstyle.Satellite{})
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(style), "/tiles/v1/") {
			t.Errorf("%s: the style points at account tiles", flavor)
		}
		var head struct {
			Metadata map[string]json.RawMessage `json:"metadata"`
		}
		if err := json.Unmarshal(style, &head); err != nil {
			t.Fatal(err)
		}
		var build string
		if err := json.Unmarshal(head.Metadata["holdmytrack:style-build"], &build); err != nil || build != mapstyle.StyleBuild() {
			t.Errorf("%s: style build %q, want %q", flavor, build, mapstyle.StyleBuild())
		}
	}
}
