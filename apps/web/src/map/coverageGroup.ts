import type { LayerSpecification } from 'maplibre-gl';
import type { MapMode } from './mapMode.ts';
import { tilePath, withView, VARS_METADATA, type GroupPart, type LayerView } from './mapLayers.ts';
import { EXACT } from './fogLevels.ts';

/**
 * Fog of War (IMPLEMENTATION.md §4.2): its sources, layers, what each mode shows and how, and
 * the zoom tiers, as the layers document's `coverage` group (mapLayers.ts).
 */

const FOG_SOURCE = 'fog-vector';
const COUNTRY_FOG_SOURCE = 'country-fog';
const REGION_FOG_SOURCE = 'region-fog';
const COUNTY_FOG_SOURCE = 'county-fog';
const CITY_FOG_SOURCE = 'city-fog';

const FOG_LAYER = 'fog-veil';
const FOG_EDGE_LAYER = 'fog-edge';
const COUNTRY_FOG_LAYER = 'country-fog-fill';
const REGION_FOG_LAYER = 'region-fog-fill';
const COUNTY_FOG_LAYER = 'county-fog-fill';
const CITY_FOG_LAYER = 'city-fog-fill';
const COUNTRY_BORDER_LAYER = 'country-fog-border';
const REGION_BORDER_LAYER = 'region-fog-border';
const COUNTY_BORDER_LAYER = 'county-fog-border';
const CITY_BORDER_LAYER = 'city-fog-border';
const COUNTRY_PICKED_LAYER = 'country-fog-picked';
const REGION_PICKED_LAYER = 'region-fog-picked';
const COUNTY_PICKED_LAYER = 'county-fog-picked';
const CITY_PICKED_LAYER = 'city-fog-picked';

/** The outline an app's tap picked, by its tile `id`, which the apps bind: MapLibre Native has no
 *  feature-state to set, so where the web hovers an outline, they draw this layer over it. Null
 *  matches no outline, the sea (0) and the merged explored places (-1) included. */
const PICKED_VAR = 'fogPlace';

/** The outline fills a pointer is over, which fogPlaces.ts hit-tests, and their sources, whose
 *  `id` it sets the hover state on. */
export const PLACE_FILL_LAYERS = [COUNTRY_FOG_LAYER, REGION_FOG_LAYER, COUNTY_FOG_LAYER, CITY_FOG_LAYER];

/** Adopted, tunable bands (IMPLEMENTATION.md §4.2.4): whole countries, then regions, counties and
 *  cities, then exact coverage. A layer shows at minzoom <= zoom < maxzoom, so the levels never
 *  overlap. */
const COUNTRY_MAX_ZOOM = 3;
const REGION_MAX_ZOOM = 6;
const COUNTY_MAX_ZOOM = 8;
const CITY_MAX_ZOOM = 11;
/** The last zoom the outline tiles are made for (internal/httpapi's cacheMaxZoom): about 10 m a
 *  tile unit; MapLibre enlarges them past it. */
const OUTLINE_TILE_MAX_ZOOM = 10;

/** The zoom Fog's finest tiles are stored at (internal/fog's Zoom); MapLibre enlarges them past it. */
const FOG_MAX_ZOOM = 14;

/** The blurred edge's width, and its blur, by zoom: about a cleared corridor's own width zoomed
 *  out, where a wider one would smudge it, to 14 px close in. */
const FOG_EDGE_WIDTH = ['interpolate', ['exponential', 2], ['zoom'], 10, 1, 13, 5, 15, 14, 18, 20];

/**
 * The veil over each base. Fog is always darker than what it reveals: dark ink over a light map,
 * black over a dark one, so explored ground stays the lighter part of the map in either theme, and
 * a cream mist over imagery, whose own darks would hide a dark veil. The Country/Region fills take
 * the same, so nothing shifts at a tier.
 * - `border`: an unvisited outline, drawn on the veil, so its opposite.
 * - `visited`: a visited outline and a hovered visited place's tint, drawn on the basemap, so the
 *   basemap's opposite: the veil's own colour where that contrasts with the basemap, cream on dark.
 * - `hover`: an unvisited place's veil under the pointer, thinned enough to read as opening up.
 * - `outline`: a hovered or picked outline's opacity, lower in cream on the dark map, where full
 *   strength glares.
 */
const LIGHT_VEIL = { color: '#202b25', opacity: 0.82, border: '#f7f4ec', visited: '#202b25', hover: 0.68, outline: 0.95 };
const DARK_VEIL = { color: '#000000', opacity: 0.7, border: '#f7f4ec', visited: '#f7f4ec', hover: 0.3, outline: 0.7 };
const IMAGERY_VEIL = { color: '#f7f4ec', opacity: 0.82, border: '#202b25', visited: '#f7f4ec', hover: 0.68, outline: 0.95 };
const BORDER_OPACITY = 0.22;
const BORDER_WIDTH = 0.7;
/** Over satellite imagery, whose colours vary under every border, a faint border vanishes. */
const SATELLITE_BORDER_OPACITY = 0.5;
const SATELLITE_BORDER_WIDTH = 1;
const HOVER_BORDER_WIDTH = 2.5;

/** An outline is hovered while fogPlaces.ts sets its `hover` state. */
const HOVERED = ['boolean', ['feature-state', 'hover'], false];

/** The Country/Region outlines are Overture Maps' divisions, built from OpenStreetMap (IMPLEMENTATION.md §4.2.4). */
const BOUNDARIES_ATTRIBUTION = '<a href="https://overturemaps.org">Overture Maps</a>';

const BORDER_LAYERS = [COUNTRY_BORDER_LAYER, REGION_BORDER_LAYER, COUNTY_BORDER_LAYER, CITY_BORDER_LAYER];
const PICKED_LAYERS = [COUNTRY_PICKED_LAYER, REGION_PICKED_LAYER, COUNTY_PICKED_LAYER, CITY_PICKED_LAYER];
const FOG_LAYERS = [FOG_LAYER, FOG_EDGE_LAYER, ...PLACE_FILL_LAYERS, ...BORDER_LAYERS, ...PICKED_LAYERS];

/** One mode's view over a base that reads `dark`, or over imagery. */
function coverageView(mode: MapMode, dark: boolean, satellite = false): LayerView {
  const veil = satellite ? IMAGERY_VEIL : dark ? DARK_VEIL : LIGHT_VEIL;
  const shown = (on: boolean) => ({ visibility: on ? 'visible' : 'none' });
  const fill = { 'fill-color': veil.color, 'fill-opacity': veil.opacity };
  // Every outline is in the tile; the veil covers the unvisited and the sea. A hovered outline
  // thins its veil, or tints a visited one, so the place under the pointer stands out.
  const outlineFill = {
    'fill-color': ['case', ['get', 'visited'], veil.visited, veil.color],
    'fill-opacity': ['case', ['get', 'visited'], ['case', HOVERED, 0.12, 0], ['case', HOVERED, veil.hover, veil.opacity]],
  };
  const border = {
    'line-color': ['case', ['get', 'visited'], veil.visited, veil.border],
    'line-opacity': ['case', HOVERED, veil.outline, satellite ? SATELLITE_BORDER_OPACITY : BORDER_OPACITY],
    'line-width': ['case', HOVERED, HOVER_BORDER_WIDTH, satellite ? SATELLITE_BORDER_WIDTH : BORDER_WIDTH],
  };
  return {
    layout: {
      ...Object.fromEntries(FOG_LAYERS.map((id) => [id, shown(mode === 'fog')])),
    },
    paint: {
      [FOG_LAYER]: fill,
      [FOG_EDGE_LAYER]: { 'line-color': veil.color, 'line-opacity': veil.opacity },
      ...Object.fromEntries(PLACE_FILL_LAYERS.map((id) => [id, outlineFill])),
      ...Object.fromEntries(BORDER_LAYERS.map((id) => [id, border])),
      // As a hovered border.
      ...Object.fromEntries(PICKED_LAYERS.map((id) => [id, { 'line-color': border['line-color'], 'line-opacity': veil.outline, 'line-width': HOVER_BORDER_WIDTH }])),
    },
  };
}

/** The `coverage` group over a basemap drawn `dark`. */
export function coverageGroup(dark: boolean, tileVersion: string, lang: string, words: { region: string; county: string }): GroupPart {
  // The outlines' names come in `lang`, part of the path so a cached tile changes with it.
  const outlines = (kind: string) => `${tilePath(kind, tileVersion)}${tileVersion ? '&' : '?'}lang=${encodeURIComponent(lang)}`;
  const base = coverageView('normal', dark);
  const layer = (spec: LayerSpecification) => withView(spec, base);
  return {
    group: {
      id: 'coverage',
      placement: 'beneath-labels',
      sources: {
        [FOG_SOURCE]: { type: 'vector', tiles: tilePath('fog-vector', tileVersion), minzoom: 0, maxzoom: FOG_MAX_ZOOM },
        // Every level has tiles at every zoom, since a locked one draws at any.
        ...Object.fromEntries(
          ([[COUNTRY_FOG_SOURCE, 'countries'], [REGION_FOG_SOURCE, 'regions'], [COUNTY_FOG_SOURCE, 'counties'], [CITY_FOG_SOURCE, 'cities']] as const).map(([id, kind]) => [
            id,
            { type: 'vector', tiles: outlines(kind), minzoom: 0, maxzoom: OUTLINE_TILE_MAX_ZOOM, attribution: BOUNDARIES_ATTRIBUTION, promoteId: 'id' },
          ]),
        ),
      },
      layers: [
        layer({
          id: FOG_LAYER,
          type: 'fill',
          source: FOG_SOURCE,
          'source-layer': 'fog',
          minzoom: CITY_MAX_ZOOM,
          filter: ['==', ['get', 'kind'], 'veil'],
        }),
        layer({
          id: FOG_EDGE_LAYER,
          type: 'line',
          source: FOG_SOURCE,
          'source-layer': 'fog',
          minzoom: CITY_MAX_ZOOM,
          filter: ['==', ['get', 'kind'], 'edge'],
          // Butt ends: the server carries each edge just past the tile, where the next tile's own
          // takes over, so a cap would double up at the join.
          layout: { 'line-join': 'round', 'line-cap': 'butt' },
          paint: { 'line-width': FOG_EDGE_WIDTH as never, 'line-blur': FOG_EDGE_WIDTH as never },
        }),
        layer({
          id: COUNTRY_FOG_LAYER,
          type: 'fill',
          source: COUNTRY_FOG_SOURCE,
          'source-layer': 'countries',
          minzoom: 0,
          maxzoom: COUNTRY_MAX_ZOOM,
          paint: { 'fill-antialias': false },
        }),
        layer({
          id: REGION_FOG_LAYER,
          type: 'fill',
          source: REGION_FOG_SOURCE,
          'source-layer': 'regions',
          minzoom: COUNTRY_MAX_ZOOM,
          maxzoom: REGION_MAX_ZOOM,
          paint: { 'fill-antialias': false },
        }),
        // Antialiasing drew a hairline where two locked places meet; the borders below draw them
        // on purpose.
        ...([
          [COUNTY_FOG_LAYER, COUNTY_FOG_SOURCE, 'counties', REGION_MAX_ZOOM, COUNTY_MAX_ZOOM],
          [CITY_FOG_LAYER, CITY_FOG_SOURCE, 'cities', COUNTY_MAX_ZOOM, CITY_MAX_ZOOM],
        ] as const).map(([id, source, sourceLayer, minzoom, maxzoom]) =>
          layer({ id, type: 'fill', source, 'source-layer': sourceLayer, minzoom, maxzoom, paint: { 'fill-antialias': false } }),
        ),
        ...([
          [COUNTRY_BORDER_LAYER, COUNTRY_FOG_SOURCE, 'countries', 0, COUNTRY_MAX_ZOOM],
          [REGION_BORDER_LAYER, REGION_FOG_SOURCE, 'regions', COUNTRY_MAX_ZOOM, REGION_MAX_ZOOM],
          [COUNTY_BORDER_LAYER, COUNTY_FOG_SOURCE, 'counties', REGION_MAX_ZOOM, COUNTY_MAX_ZOOM],
          [CITY_BORDER_LAYER, CITY_FOG_SOURCE, 'cities', COUNTY_MAX_ZOOM, CITY_MAX_ZOOM],
        ] as const).map(([id, source, sourceLayer, minzoom, maxzoom]) =>
          layer({
            id,
            type: 'line',
            source,
            'source-layer': sourceLayer,
            minzoom,
            maxzoom,
            filter: ['!=', ['get', 'kind'], 'sea'],
            layout: { 'line-join': 'round' },
          }),
        ),
        ...([
          [COUNTRY_PICKED_LAYER, COUNTRY_FOG_SOURCE, 'countries', 0, COUNTRY_MAX_ZOOM],
          [REGION_PICKED_LAYER, REGION_FOG_SOURCE, 'regions', COUNTRY_MAX_ZOOM, REGION_MAX_ZOOM],
          [COUNTY_PICKED_LAYER, COUNTY_FOG_SOURCE, 'counties', REGION_MAX_ZOOM, COUNTY_MAX_ZOOM],
          [CITY_PICKED_LAYER, CITY_FOG_SOURCE, 'cities', COUNTY_MAX_ZOOM, CITY_MAX_ZOOM],
        ] as const).map(([id, source, sourceLayer, minzoom, maxzoom]) =>
          layer({
            id,
            type: 'line',
            source,
            'source-layer': sourceLayer,
            minzoom,
            maxzoom,
            filter: ['==', ['get', 'id'], ['var', PICKED_VAR]],
            layout: { 'line-join': 'round' },
            metadata: { [VARS_METADATA]: { filter: [PICKED_VAR] } },
          }),
        ),
      ],
    },
    vars: { [PICKED_VAR]: null },
    view: (mode, onDark, satellite) => coverageView(mode, onDark, satellite),
    // The apps' level notice names three: whole countries, then whole places, then exact
    // coverage. An installed app refuses a tier it doesn't know.
    tiers: [{ tier: 'country', below: COUNTRY_MAX_ZOOM }, { tier: 'region', below: CITY_MAX_ZOOM }, { tier: 'city' }],
    levels: [
      { level: 'country', below: COUNTRY_MAX_ZOOM, layers: [COUNTRY_FOG_LAYER, COUNTRY_BORDER_LAYER, COUNTRY_PICKED_LAYER] },
      { level: 'region', from: COUNTRY_MAX_ZOOM, below: REGION_MAX_ZOOM, layers: [REGION_FOG_LAYER, REGION_BORDER_LAYER, REGION_PICKED_LAYER], word: words.region },
      { level: 'county', from: REGION_MAX_ZOOM, below: COUNTY_MAX_ZOOM, layers: [COUNTY_FOG_LAYER, COUNTY_BORDER_LAYER, COUNTY_PICKED_LAYER], word: words.county },
      { level: 'city', from: COUNTY_MAX_ZOOM, below: CITY_MAX_ZOOM, layers: [CITY_FOG_LAYER, CITY_BORDER_LAYER, CITY_PICKED_LAYER] },
      { level: EXACT, from: CITY_MAX_ZOOM, layers: [FOG_LAYER, FOG_EDGE_LAYER] },
    ],
  };
}
