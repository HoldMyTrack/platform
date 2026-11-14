package httpapi

import (
	"net/http"
	"slices"
	"strings"
)

// spotsAreaLimit caps how many places one "Show in this area" request returns (§4.25). A
// region-sized view can hold tens of thousands of playgrounds; 2,000 badges is already a dense
// map, and the response says how many there were, so the client can ask the user to zoom in.
const spotsAreaLimit = 2000

var spotCategories = []string{"playground", "dog_park", "monument", "viewpoint", "waterfall", "history"}

// spotsAreaQuery is the places in an area, in the chosen categories, at most $8 of them,
// leaving out a retired place (docs/SPEC.md FR-14.1) unless the account $9 captured it. The area is two
// boxes (spotsInAreaSQL, $1–$6). Named places first — the ones worth a popup — then by a hash of the id: a stable order that's
// spread evenly over the area, so a cut-off leaves a thinner map rather than an empty corner.
var spotsAreaQuery = `
SELECT s.id, s.category, s.name, s.address, s.description, s.inscription, s.memorial,
       s.start_date, s.wikipedia, ST_X(p.pt), ST_Y(p.pt)
FROM spots s
CROSS JOIN LATERAL (SELECT ST_PointOnSurface(s.geom) AS pt) p
WHERE ` + spotsInAreaSQL + ` AND s.category = ANY($7)
  AND (s.retired_at IS NULL OR EXISTS (SELECT 1 FROM spot_captures c WHERE c.spot_id = s.id AND c.user_id = $9))
ORDER BY s.name IS NULL, md5(s.id::text)
LIMIT $8`

var spotsAreaCountQuery = `
SELECT count(*) FROM spots s
CROSS JOIN LATERAL (SELECT ST_PointOnSurface(s.geom) AS pt) p
WHERE ` + spotsInAreaSQL + ` AND s.category = ANY($7)
  AND (s.retired_at IS NULL OR EXISTS (SELECT 1 FROM spot_captures c WHERE c.spot_id = s.id AND c.user_id = $8))`

// spotsInAreaSQL is "s's point p.pt lies in one of the area's two boxes": $1 south, $2 north,
// the first box from $3 west to $4 east, the second from $5 to $6 (mapArea.boxes). Each box is
// its own && against constant parameters, so the planner answers the OR with two index scans on
// idx_spots_geom; an envelope built from rows (unnest) or one around both boxes scans the table.
const spotsInAreaSQL = `(
       (s.geom && ST_MakeEnvelope($3, $1, $4, $2, 4326) AND ST_Intersects(p.pt, ST_MakeEnvelope($3, $1, $4, $2, 4326)))
    OR (s.geom && ST_MakeEnvelope($5, $1, $6, $2, 4326) AND ST_Intersects(p.pt, ST_MakeEnvelope($5, $1, $6, $2, 4326))))`

// spotJSON is one place as "Show in this area" returns it — the tiles' `spots` layer's
// properties (§4.25), with a field absent when OSM has none.
type spotJSON struct {
	ID          int64   `json:"id"`
	Category    string  `json:"category"`
	Name        *string `json:"name,omitempty"`
	Address     *string `json:"address,omitempty"`
	Description *string `json:"description,omitempty"`
	Inscription *string `json:"inscription,omitempty"`
	Memorial    *string `json:"memorial,omitempty"`
	StartDate   *string `json:"start_date,omitempty"`
	Wikipedia   *string `json:"wikipedia,omitempty"`
	Lon         float64 `json:"lon"`
	Lat         float64 `json:"lat"`
}

type spotsAreaResponse struct {
	Spots []spotJSON `json:"spots"`
	// Total is how many places the area holds in those categories; more than len(Spots) when
	// the response was cut at spotsAreaLimit.
	Total int `json:"total"`
}

// handleSpotsInArea serves `GET /v1/spots?bbox=west,south,east,north&categories=a,b` — "Show in
// this area" below the zoom the spots tiles start at (FR-14.4). The places are the same for
// everyone but the retired ones, which only an account that captured one gets back; it's behind
// the session like the tiles.
func (s *Server) handleSpotsInArea(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	area, ok := parseBBox(q.Get("bbox"))
	if !ok {
		writeAPIError(w, "bbox must be west,south,east,north in degrees, south < north", http.StatusBadRequest)
		return
	}
	var categories []string
	for c := range strings.SplitSeq(q.Get("categories"), ",") {
		if !slices.Contains(spotCategories, c) {
			writeAPIError(w, "categories must be one or more of "+strings.Join(spotCategories, ","), http.StatusBadRequest)
			return
		}
		categories = append(categories, c)
	}

	resp := spotsAreaResponse{Spots: []spotJSON{}}
	ctx := r.Context()
	userID := userIDFromContext(ctx)
	w1, e1, w2, e2 := area.boxes()
	if err := s.pool.QueryRow(ctx, spotsAreaCountQuery, area.south, area.north, w1, e1, w2, e2, categories, userID).Scan(&resp.Total); err != nil {
		if clientGone(w, r) {
			return
		}
		s.log.Error("spots area count failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	rows, err := s.pool.Query(ctx, spotsAreaQuery, area.south, area.north, w1, e1, w2, e2, categories, spotsAreaLimit, userID)
	if err != nil {
		if clientGone(w, r) {
			return
		}
		s.log.Error("spots area query failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	defer rows.Close()
	for rows.Next() {
		var sp spotJSON
		if err := rows.Scan(&sp.ID, &sp.Category, &sp.Name, &sp.Address, &sp.Description, &sp.Inscription,
			&sp.Memorial, &sp.StartDate, &sp.Wikipedia, &sp.Lon, &sp.Lat); err != nil {
			if clientGone(w, r) {
				return
			}
			s.log.Error("spots area scan failed", "err", err)
			writeAPIError(w, "internal error", http.StatusInternalServerError)
			return
		}
		resp.Spots = append(resp.Spots, sp)
	}
	if err := rows.Err(); err != nil {
		if clientGone(w, r) {
			return
		}
		s.log.Error("spots area rows failed", "err", err)
		writeAPIError(w, "internal error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, resp)
}
