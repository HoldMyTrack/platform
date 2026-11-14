package httpapi

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"sort"
	"strconv"
	"strings"

	"github.com/HoldMyTrack/platform/services/server/internal/i18n"
	"github.com/jackc/pgx/v5"
)

// The Profile page's explored places (docs/SPEC.md FR-6.3): every country the account has been in,
// and down the one place `?place=` opens, its regions, counties and the cities' names, each with
// how many of the places below it the account has explored out of how many it holds. A link
// opens a level, as the page's other toggles are links (ADR-0012): only the opened chain is
// queried, never the account's thousands of cities at once.
//
// Explored is the map's own sets (visitedCTEs), so the page and the Fog tooltip agree; the totals
// are the seed's. A level a country lacks is skipped: a country without regions opens on its
// counties, a region without counties on its cities. Stand-ins are no place of their own and
// aren't listed.

// explorationView is the section's rows, the countries, with the opened one's children in it.
type explorationView struct {
	Rows []explorationRow
	// Open is the opened chain's deepest place, for the page's other links to keep.
	Open string
}

type explorationRow struct {
	Name   string
	Counts string
	// Href opens the row, or closes it when it's open (its parent's place).
	Href     string
	Open     bool
	Children []explorationRow
	// Cities are the opened row's explored cities by name, when its children are cities.
	Cities []string
}

// explorationPlace is a parsed `?place=`: the level and its id (a country's code, else a row id).
type explorationPlace struct {
	Level string
	ID    string
}

// parseExplorationPlace reads `country:US`, `region:123` or `county:456`; anything else opens
// nothing.
func parseExplorationPlace(s string) (explorationPlace, bool) {
	level, id, ok := strings.Cut(s, ":")
	if !ok || id == "" {
		return explorationPlace{}, false
	}
	switch level {
	case "country":
		if len(id) > 3 || strings.ToUpper(id) != id {
			return explorationPlace{}, false
		}
	case "region", "county":
		if n, err := strconv.Atoi(id); err != nil || n <= 0 {
			return explorationPlace{}, false
		}
	default:
		return explorationPlace{}, false
	}
	return explorationPlace{level, id}, true
}

func (p explorationPlace) String() string { return p.Level + ":" + p.ID }

// placeCounts is how many of each level below a place holds and the account has explored.
type placeCounts struct {
	Regions, RegionsTotal   int64
	Counties, CountiesTotal int64
	Cities, CitiesTotal     int64
}

// countryWords are what a country calls its regions and counties (its commonest local_type),
// empty where it has none of its own.
type countryWords struct{ Region, County string }

// explorationCounts is a row's counts line, a level below at a time, each in its country's own
// word where the catalog has it, else the generic one: "12 of 50 states · 211 of 3,143 counties".
func explorationCounts(l *i18n.Localizer, words countryWords, c placeCounts) string {
	word := func(own, generic string) string {
		if own != "" && l.Has("fog.count."+own) {
			return "fog.count." + own
		}
		return "fog.count." + generic
	}
	var parts []string
	if c.RegionsTotal > 0 {
		parts = append(parts, l.N(word(words.Region, "region"), c.RegionsTotal, "explored", c.Regions))
	}
	if c.CountiesTotal > 0 {
		parts = append(parts, l.N(word(words.County, "county"), c.CountiesTotal, "explored", c.Counties))
	}
	if c.CitiesTotal > 0 {
		parts = append(parts, l.N("fog.count.city", c.CitiesTotal, "explored", c.Cities))
	}
	return strings.Join(parts, " · ")
}

// placeRow is a place as a query returns it, before it's a row.
type placeRow struct {
	Place  explorationPlace
	Name   string
	Words  countryWords
	Counts placeCounts
}

// sortPlaces puts the most explored first: by cities, then counties, then regions, then name.
func sortPlaces(rows []placeRow) {
	sort.SliceStable(rows, func(i, j int) bool {
		a, b := rows[i].Counts, rows[j].Counts
		if a.Cities != b.Cities {
			return a.Cities > b.Cities
		}
		if a.Counties != b.Counties {
			return a.Counties > b.Counties
		}
		if a.Regions != b.Regions {
			return a.Regions > b.Regions
		}
		return rows[i].Name < rows[j].Name
	})
}

// explorationHref is the profile with place opened (none for the zero place), keeping the page's
// other toggles, and scrolled to the section.
func explorationHref(shade, bucket string, place explorationPlace) string {
	href := profileHref(shade, bucket, place.String())
	if place.Level == "" {
		href = profileHref(shade, bucket, "")
	}
	return href + "#exploration"
}

// buildExploration is the section for the account, with place opened down to its chain.
func (s *Server) buildExploration(ctx context.Context, l *i18n.Localizer, userID, lang string, open explorationPlace, opened bool, shade, bucket string) (explorationView, error) {
	// The chain from the country down to the opened place, so each level shows opened.
	var chain []explorationPlace
	if opened {
		var err error
		if chain, err = s.explorationChain(ctx, open); err != nil {
			return explorationView{}, err
		}
	}
	countries, err := s.explorationCountries(ctx, userID, lang)
	if err != nil {
		return explorationView{}, err
	}
	view := explorationView{}
	if len(chain) > 0 {
		view.Open = chain[len(chain)-1].String()
	}
	rows, err := s.explorationRows(ctx, l, userID, lang, countries, chain, explorationPlace{}, shade, bucket)
	view.Rows = rows
	return view, err
}

// explorationRows turns places into rows, the one on chain opened with its children in it.
func (s *Server) explorationRows(ctx context.Context, l *i18n.Localizer, userID, lang string, places []placeRow, chain []explorationPlace, parent explorationPlace, shade, bucket string) ([]explorationRow, error) {
	sortPlaces(places)
	rows := make([]explorationRow, 0, len(places))
	for _, p := range places {
		row := explorationRow{Name: p.Name, Counts: explorationCounts(l, p.Words, p.Counts), Href: explorationHref(shade, bucket, p.Place)}
		if len(chain) > 0 && chain[0] == p.Place {
			row.Open = true
			row.Href = explorationHref(shade, bucket, parent)
			children, cities, err := s.explorationChildren(ctx, userID, lang, p)
			if err != nil {
				return nil, err
			}
			row.Cities = cities
			if row.Children, err = s.explorationRows(ctx, l, userID, lang, children, chain[1:], p.Place, shade, bucket); err != nil {
				return nil, err
			}
		}
		rows = append(rows, row)
	}
	return rows, nil
}

// explorationChain is the places from the country down to place, or none for a place that
// doesn't exist.
func (s *Server) explorationChain(ctx context.Context, place explorationPlace) ([]explorationPlace, error) {
	var country string
	var region *int64
	switch place.Level {
	case "country":
		return []explorationPlace{place}, nil
	case "region":
		err := s.pool.QueryRow(ctx, `SELECT c.code FROM admin_regions r JOIN admin_countries c ON c.id = r.country_id WHERE r.id = $1`, place.ID).Scan(&country)
		if err != nil {
			return nil, noRows(err)
		}
		return []explorationPlace{{"country", country}, place}, nil
	default: // county
		err := s.pool.QueryRow(ctx, `
			SELECT c.code, CASE WHEN r.overture_id LIKE 'country:%' THEN NULL ELSE r.id END
			FROM admin_counties k JOIN admin_countries c ON c.id = k.country_id
			LEFT JOIN admin_regions r ON r.id = k.region_id
			WHERE k.id = $1`, place.ID).Scan(&country, &region)
		if err != nil {
			return nil, noRows(err)
		}
		chain := []explorationPlace{{"country", country}}
		if region != nil {
			chain = append(chain, explorationPlace{"region", strconv.FormatInt(*region, 10)})
		}
		return append(chain, place), nil
	}
}

// noRows makes a place that isn't there no error: the section opens nothing.
func noRows(err error) error {
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	return err
}

// exploredUnder is the SQL for how many of `table`'s own places under o (by `parent`) are in the
// account's `visited` set.
func exploredUnder(visited, table, own, parent string) string {
	return fmt.Sprintf(`(SELECT count(*) FROM %s v JOIN %s x ON x.id = v.id WHERE x.%s = o.id AND %s)`, visited, table, parent, own)
}

// explorationCountries is every country the account has been in.
func (s *Server) explorationCountries(ctx context.Context, userID, lang string) ([]placeRow, error) {
	rows, err := s.pool.Query(ctx, `
		WITH `+visitedCTEs("$1")+`
		SELECT o.code, COALESCE(o.names ->> $2::text, o.name), o.region_word, o.county_word,
		       `+exploredUnder("v_region", "admin_regions", "x.overture_id NOT LIKE 'country:%'", "country_id")+`, o.regions_total,
		       `+exploredUnder("v_county", "admin_counties", "x.kind = 'county'", "country_id")+`, o.counties_total,
		       `+exploredUnder("v_city", "admin_cities", "x.kind = 'city'", "country_id")+`, o.cities_total
		FROM admin_countries o WHERE o.id IN (SELECT id FROM v_country)`, userID, lang)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []placeRow
	for rows.Next() {
		var p placeRow
		p.Place.Level = "country"
		c := &p.Counts
		if err := rows.Scan(&p.Place.ID, &p.Name, &p.Words.Region, &p.Words.County,
			&c.Regions, &c.RegionsTotal, &c.Counties, &c.CountiesTotal, &c.Cities, &c.CitiesTotal); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// explorationChildren is what an opened place lists: a country its regions, or its counties
// when it has no regions; a region its counties; else the cities' names.
func (s *Server) explorationChildren(ctx context.Context, userID, lang string, p placeRow) ([]placeRow, []string, error) {
	switch {
	case p.Place.Level == "country" && p.Counts.RegionsTotal > 0:
		rows, err := s.explorationPlaces(ctx, userID, lang, "region", `
			SELECT o.id, COALESCE(o.names ->> $2::text, o.name), 0::bigint, 0::bigint,
			       `+exploredUnder("v_county", "admin_counties", "x.kind = 'county'", "region_id")+`, o.counties_total,
			       `+exploredUnder("v_city", "admin_cities", "x.kind = 'city'", "region_id")+`, o.cities_total
			FROM admin_regions o JOIN admin_countries c ON c.id = o.country_id
			WHERE c.code = $3 AND o.overture_id NOT LIKE 'country:%' AND o.id IN (SELECT id FROM v_region)`, p.Place.ID, p.Words)
		return rows, nil, err
	case (p.Place.Level == "country" || p.Place.Level == "region") && p.Counts.CountiesTotal > 0:
		filter := `o.region_id = $3::int`
		if p.Place.Level == "country" {
			filter = `o.country_id = (SELECT id FROM admin_countries WHERE code = $3)`
		}
		rows, err := s.explorationPlaces(ctx, userID, lang, "county", `
			SELECT o.id, COALESCE(o.names ->> $2::text, o.name), 0::bigint, 0::bigint, 0::bigint, 0::bigint,
			       `+exploredUnder("v_city", "admin_cities", "x.kind = 'city'", "county_id")+`, o.cities_total
			FROM admin_counties o
			WHERE `+filter+` AND o.kind = 'county' AND o.id IN (SELECT id FROM v_county)`, p.Place.ID, p.Words)
		return rows, nil, err
	default:
		filter := map[string]string{
			"country": `o.country_id = (SELECT id FROM admin_countries WHERE code = $3)`,
			"region":  `o.region_id = $3::int`,
			"county":  `o.county_id = $3::int`,
		}[p.Place.Level]
		rows, err := s.pool.Query(ctx, `
			WITH `+visitedCTEs("$1")+`
			SELECT COALESCE(o.names ->> $2::text, o.name) AS name FROM admin_cities o
			WHERE `+filter+` AND o.kind = 'city' AND o.id IN (SELECT id FROM v_city)
			ORDER BY name`, userID, lang, p.Place.ID)
		if err != nil {
			return nil, nil, err
		}
		defer rows.Close()
		var cities []string
		for rows.Next() {
			var name string
			if err := rows.Scan(&name); err != nil {
				return nil, nil, err
			}
			cities = append(cities, name)
		}
		return nil, cities, rows.Err()
	}
}

// explorationPlaces runs one of explorationChildren's region or county queries: id, name and
// the counts in placeCounts' order, for the account ($1), language ($2) and parent ($3). The
// rows keep their country's words.
func (s *Server) explorationPlaces(ctx context.Context, userID, lang, level, query, parent string, words countryWords) ([]placeRow, error) {
	rows, err := s.pool.Query(ctx, `WITH `+visitedCTEs("$1")+query, userID, lang, parent)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []placeRow
	for rows.Next() {
		var id int64
		p := placeRow{Words: words}
		c := &p.Counts
		if err := rows.Scan(&id, &p.Name, &c.Regions, &c.RegionsTotal, &c.Counties, &c.CountiesTotal, &c.Cities, &c.CitiesTotal); err != nil {
			return nil, err
		}
		p.Place = explorationPlace{level, strconv.FormatInt(id, 10)}
		out = append(out, p)
	}
	return out, rows.Err()
}

// explorationQuery is the place query parameter's value, for links that keep it.
func explorationQuery(place string) string {
	if place == "" {
		return ""
	}
	return "place=" + url.QueryEscape(place)
}
