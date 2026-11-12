package httpapi

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/HoldMyTrack/platform/services/server/internal/tilemath"
)

// A place's tile feature counts the places of each level below it the account has been in, out
// of how many it holds, a county explored through a city in it included; a stand-in counts
// nothing. Read from the live query with its features as JSON in place of the vector tile.
func TestAdminTilesCountTheExploredPlacesBelow(t *testing.T) {
	d := newDBTest(t)
	ctx := context.Background()
	at := [2]float64{-34.75, -44.5} // open ocean in the South Atlantic no other test uses
	stamp := time.Now().UnixNano()
	insert := func(sql string, args ...any) int {
		t.Helper()
		var id int
		if err := d.pool.QueryRow(ctx, sql+` RETURNING id`, args...).Scan(&id); err != nil {
			t.Fatal(err)
		}
		return id
	}
	box := func(x0, y0, x1, y1 float64) string {
		return fmt.Sprintf(`ST_Multi(ST_MakeEnvelope(%v, %v, %v, %v, 4326))`, x0, y0, x1, y1)
	}
	// A country of one region with two counties, the west one holding two cities and land
	// outside them; the account has been in one city only.
	country := insert(`INSERT INTO admin_countries (code, name, region_word, county_word, regions_total, counties_total, cities_total, geom)
		VALUES ($1, 'Counted', 'state', 'parish', 1, 2, 2, `+box(-35, -45, -34, -44)+`)`, fmt.Sprintf("TC%d", stamp))
	region := insert(`INSERT INTO admin_regions (country_id, overture_id, name, counties_total, cities_total, geom)
		VALUES ($1, $2, 'Counted State', 2, 2, `+box(-35, -45, -34, -44)+`)`, country, fmt.Sprintf("test-count-r-%d", stamp))
	west := insert(`INSERT INTO admin_counties (overture_id, kind, country_id, region_id, name, cities_total, geom)
		VALUES ($1, 'county', $2, $3, 'West Parish', 2, `+box(-35, -45, -34.5, -44)+`)`, fmt.Sprintf("test-count-w-%d", stamp), country, region)
	east := insert(`INSERT INTO admin_counties (overture_id, kind, country_id, region_id, name, geom)
		VALUES ($1, 'county', $2, $3, 'East Parish', `+box(-34.5, -45, -34, -44)+`)`, fmt.Sprintf("test-count-e-%d", stamp), country, region)
	town := insert(`INSERT INTO admin_cities (overture_id, kind, country_id, region_id, county_id, name, geom)
		VALUES ($1, 'city', $2, $3, $4, 'Town', `+box(-34.9, -44.6, -34.7, -44.4)+`)`, fmt.Sprintf("test-count-t-%d", stamp), country, region, west)
	village := insert(`INSERT INTO admin_cities (overture_id, kind, country_id, region_id, county_id, name, geom)
		VALUES ($1, 'city', $2, $3, $4, 'Village', `+box(-34.65, -44.6, -34.55, -44.4)+`)`, fmt.Sprintf("test-count-v-%d", stamp), country, region, west)
	rest := insert(`INSERT INTO admin_cities (overture_id, kind, country_id, region_id, county_id, name, geom)
		VALUES ($1, 'county', $2, $3, $4, 'West Parish', `+box(-35, -45, -34.95, -44)+`)`, fmt.Sprintf("test-count-x-%d", stamp), country, region, west)

	me := d.newAccount(false)
	t.Cleanup(func() {
		ctx := context.Background()
		d.pool.Exec(ctx, `DELETE FROM activities WHERE user_id = $1`, me.id)
		d.pool.Exec(ctx, `DELETE FROM admin_cities WHERE id = ANY($1)`, []int{town, village, rest})
		d.pool.Exec(ctx, `DELETE FROM admin_counties WHERE id = ANY($1)`, []int{west, east})
		d.pool.Exec(ctx, `DELETE FROM admin_regions WHERE id = $1`, region)
		d.pool.Exec(ctx, `DELETE FROM admin_countries WHERE id = $1`, country)
	})
	activity := d.newActivity(me, testActivity{activityType: "walking", at: &at})
	if _, err := d.pool.Exec(ctx, `INSERT INTO activity_city VALUES ($1, $2)`, activity, town); err != nil {
		t.Fatal(err)
	}

	features := func(l adminLayer, q adminTileQueries) map[string]map[string]any {
		t.Helper()
		const z = 7
		x, y := tilemath.LonLatToTile(at[0], at[1], z)
		live := strings.Replace(q.live, fmt.Sprintf("ST_AsMVT(t, '%s', 4096, 'geom')", l.name), "json_agg(t)", 1)
		var built bool
		var raw []byte
		if err := d.pool.QueryRow(ctx, live, z, x, y, me.id, "en").Scan(&built, &raw); err != nil {
			t.Fatalf("%s: %v", l.name, err)
		}
		var rows []map[string]any
		if err := json.Unmarshal(raw, &rows); err != nil {
			t.Fatalf("%s: %v", l.name, err)
		}
		byName := map[string]map[string]any{}
		for _, r := range rows {
			if name, ok := r["name"].(string); ok {
				byName[fmt.Sprint(name, " ", r["kind"])] = r
			}
		}
		return byName
	}
	want := func(feature map[string]any, fields string) {
		t.Helper()
		var got []string
		for _, f := range strings.Fields(fields) {
			k, _, _ := strings.Cut(f, "=")
			got = append(got, fmt.Sprintf("%s=%v", k, feature[k]))
		}
		if strings.Join(got, " ") != fields {
			t.Errorf("%v: got %s, want %s", feature["name"], strings.Join(got, " "), fields)
		}
	}

	countries := features(countryLayer, countryFogQueries)
	want(countries["Counted country"], "visited=true regions=1 regions_total=1 counties=1 counties_total=2 cities=1 cities_total=2 region_word=state county_word=parish")
	regions := features(regionLayer, regionFogQueries)
	want(regions["Counted State region"], "visited=true counties=1 counties_total=2 cities=1 cities_total=2 county_word=parish")
	counties := features(countyLayer, countyFogQueries)
	want(counties["West Parish county"], "visited=true cities=1 cities_total=2")
	want(counties["East Parish county"], "visited=false cities=<nil> cities_total=<nil>")
	cities := features(cityLayer, cityFogQueries)
	want(cities["Town city"], "visited=true cities=<nil>")
	want(cities["West Parish county"], "visited=false cities=<nil>")
}
