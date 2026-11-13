package httpapi

// Covers docs/SPEC.md FR-7.3.

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/HoldMyTrack/platform/services/server/internal/i18n"
)

func TestParseExplorationPlace(t *testing.T) {
	for in, want := range map[string]string{
		"country:US": "country:US",
		"region:12":  "region:12",
		"county:7":   "county:7",
		"country:us": "",
		"region:x":   "",
		"region:-1":  "",
		"city:3":     "",
		"county":     "",
		"":           "",
	} {
		got, ok := parseExplorationPlace(in)
		if (want == "") == ok || (ok && got.String() != want) {
			t.Errorf("parseExplorationPlace(%q) = %v, %v; want %q", in, got, ok, want)
		}
	}
}

func TestExplorationCounts(t *testing.T) {
	en := i18n.Get("en")
	c := placeCounts{Regions: 12, RegionsTotal: 50, Counties: 211, CountiesTotal: 3143, Cities: 1, CitiesTotal: 29800}
	if got, want := explorationCounts(en, countryWords{"state", "county"}, c), "12 of 50 states · 211 of 3,143 counties · 1 of 29,800 cities"; got != want {
		t.Errorf("own words: %q, want %q", got, want)
	}
	// A word the catalog lacks reads as the generic one; a level with none is left out.
	c = placeCounts{Cities: 3, CitiesTotal: 7, CountiesTotal: 0}
	if got, want := explorationCounts(en, countryWords{"no such word", ""}, c), "3 of 7 cities"; got != want {
		t.Errorf("generic: %q, want %q", got, want)
	}
	if got, want := explorationCounts(i18n.Get("ru"), countryWords{"state", ""}, placeCounts{Regions: 2, RegionsTotal: 5}), "2 из 5 штатов"; got != want {
		t.Errorf("ru: %q, want %q", got, want)
	}
}

func TestSortPlaces(t *testing.T) {
	rows := []placeRow{
		{Name: "B", Counts: placeCounts{Cities: 1}},
		{Name: "A", Counts: placeCounts{Cities: 1}},
		{Name: "C", Counts: placeCounts{Cities: 5}},
		{Name: "D", Counts: placeCounts{Cities: 1, Counties: 2}},
	}
	sortPlaces(rows)
	var got []string
	for _, r := range rows {
		got = append(got, r.Name)
	}
	if strings.Join(got, "") != "CDAB" {
		t.Errorf("order %v, want C D A B", got)
	}
}

// The page lists the countries the account has been in and opens one place's chain: a country
// its regions, a region its counties, a county its cities by name, with what each holds.
func TestProfileExploration(t *testing.T) {
	d := newDBTest(t)
	ctx := context.Background()
	stamp := time.Now().UnixNano()
	code := fmt.Sprintf("X%d", stamp%100)
	var country, region, county, inside, outside int
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	must(d.pool.QueryRow(ctx, `INSERT INTO admin_countries (code, name, geom, regions_total, counties_total, cities_total, region_word)
		VALUES ($1, 'Testland', ST_Multi(ST_MakeEnvelope(-25, -45, -24, -44, 4326)), 3, 4, 9, 'state') RETURNING id`, code).Scan(&country))
	must(d.pool.QueryRow(ctx, `INSERT INTO admin_regions (country_id, overture_id, name, geom, counties_total, cities_total)
		VALUES ($1, $2, 'North', ST_Multi(ST_MakeEnvelope(-25, -45, -24, -44, 4326)), 2, 5) RETURNING id`, country, fmt.Sprintf("test-r-%d", stamp)).Scan(&region))
	must(d.pool.QueryRow(ctx, `INSERT INTO admin_counties (overture_id, kind, country_id, region_id, name, geom, cities_total)
		VALUES ($1, 'county', $2, $3, 'Lake', ST_Multi(ST_MakeEnvelope(-25, -45, -24, -44, 4326)), 2) RETURNING id`, fmt.Sprintf("test-k-%d", stamp), country, region).Scan(&county))
	for _, c := range []struct {
		name string
		id   *int
	}{{"Harbor", &inside}, {"Upton", &outside}} {
		must(d.pool.QueryRow(ctx, `INSERT INTO admin_cities (overture_id, kind, country_id, region_id, county_id, name, geom)
			VALUES ($1, 'city', $2, $3, $4, $5, ST_Multi(ST_MakeEnvelope(-25, -45, -24, -44, 4326))) RETURNING id`,
			fmt.Sprintf("test-c-%s-%d", c.name, stamp), country, region, county, c.name).Scan(c.id))
	}
	t.Cleanup(func() {
		ctx := context.Background()
		d.pool.Exec(ctx, `DELETE FROM admin_cities WHERE id = ANY($1)`, []int{inside, outside})
		d.pool.Exec(ctx, `DELETE FROM admin_counties WHERE id = $1`, county)
		d.pool.Exec(ctx, `DELETE FROM admin_regions WHERE id = $1`, region)
		d.pool.Exec(ctx, `DELETE FROM admin_countries WHERE id = $1`, country)
	})

	me := d.newAccount(false)
	at := [2]float64{-24.5, -44.5}
	activity := d.newActivity(me, testActivity{activityType: "walking", at: &at})
	must(func() error {
		_, err := d.pool.Exec(ctx, `INSERT INTO activity_city VALUES ($1, $2)`, activity, inside)
		return err
	}())

	page := func(query string) string {
		t.Helper()
		rec := d.do(me, "GET", "/profile"+query, nil)
		if rec.Code != http.StatusOK {
			t.Fatalf("%s: status %d", query, rec.Code)
		}
		return rec.Body.String()
	}
	body := page("")
	for _, want := range []string{"Testland", "1 of 3 states", "1 of 4 counties", "1 of 9 cities", "place=country%3A" + code} {
		if !strings.Contains(body, want) {
			t.Errorf("closed: no %q", want)
		}
	}
	if strings.Contains(body, "North") {
		t.Errorf("closed: a region is listed")
	}
	body = page(fmt.Sprintf("?place=county:%d", county))
	for _, want := range []string{"Testland", "North", "1 of 2 counties", "Lake", "1 of 2 cities", "Harbor"} {
		if !strings.Contains(body, want) {
			t.Errorf("county open: no %q", want)
		}
	}
	if strings.Contains(body, "Upton") {
		t.Errorf("county open: a city not been in is listed")
	}
	// A place that isn't there opens nothing.
	if body := page("?place=county:999999999"); !strings.Contains(body, "Testland") || strings.Contains(body, "North") {
		t.Errorf("missing place: the section should list the country closed")
	}
}
