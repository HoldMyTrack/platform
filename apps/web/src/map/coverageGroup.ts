import type { LayerSpecification } from 'maplibre-gl';
import type { MapMode } from './mapMode';
import { tilePath, withView, type GroupPart, type LayerView } from './mapLayers.ts';

/**
 * Fog of War and Heatmap (IMPLEMENTATION.md §4.2): their sources, layers, what each mode shows
 * and how, and the zoom tiers, as the layers document's `coverage` group (mapLayers.ts).
 */

const FOG_SOURCE = 'fog-vector';
const COUNTRY_FOG_SOURCE = 'country-fog';
const REGION_FOG_SOURCE = 'region-fog';
const PLACE_FOG_SOURCE = 'place-fog';
const HEAT_POINTS_SOURCE = 'heat-points';

const HEATMAP_DIM_LAYER = 'heatmap-dim';
const FOG_LAYER = 'fog-veil';
const FOG_EDGE_LAYER = 'fog-edge';
const COUNTRY_FOG_LAYER = 'country-fog-fill';
const REGION_FOG_LAYER = 'region-fog-fill';
const PLACE_FOG_LAYER = 'place-fog-fill';
const COUNTRY_BORDER_LAYER = 'country-fog-border';
const REGION_BORDER_LAYER = 'region-fog-border';
const PLACE_BORDER_LAYER = 'place-fog-border';

/** PROTOTYPE (FOG_REWORK.md "Borders and names"): the outline fills a pointer is over, which
 *  fogPlaces.ts hit-tests, and their sources, whose `id` it sets the hover state on. */
export const PLACE_FILL_LAYERS = [COUNTRY_FOG_LAYER, REGION_FOG_LAYER, PLACE_FOG_LAYER];
const HEAT_POINTS_LAYER = 'heat-points-circles';

/** Adopted, tunable bands (IMPLEMENTATION.md §4.2.4): whole countries, then regions, then exact
 *  coverage. A layer shows at minzoom <= zoom < maxzoom, so the tiers never overlap. */
const COUNTRY_MAX_ZOOM = 3;
const REGION_MAX_ZOOM = 7;
/** PROTOTYPE (FOG_REWORK.md): cities, and the county land outside them, below exact coverage. */
const PLACE_MAX_ZOOM = 11;

/** The zoom Fog's finest tiles are stored at (internal/fog's Zoom); MapLibre enlarges them past it. */
const FOG_MAX_ZOOM = 14;

/** The last zoom the server makes heat-points tiles for (internal/fog's HeatPointsMaxZoom): its
 *  cells are the stored count tiles' own pixels, ~19 m. */
const HEAT_POINTS_MAX_ZOOM = 15;

/** A cell's width in screen pixels at its tile's own zoom: 64 cells to a 512 px tile. */
const CELL_PX = 8;

/** A circle's radius in cells: wide enough that a route's cells blend into a line, narrow enough
 *  that streets a block apart stay apart. The server's neighbour weighting assumes it
 *  (internal/fog's heatRadiusCells, held to it by a test there). */
const RADIUS_PER_CELL = 1.6;

/** MapLibre's circle peaks at about 0.4 of its weight; this lifts it back, so with the server's
 *  neighbour weighting (internal/fog's weighNeighbours) each circle peaks at its own weight. */
const HEAT_POINTS_INTENSITY = 2.5;

/** Green where an account went once, through yellow and orange to red at its busiest; nothing
 *  below a twentieth, so a soft edge ends. */
const HEAT_RAMP: [number, string][] = [
  [0, 'rgba(60,200,40,0)'],
  [0.05, 'rgba(60,200,40,0)'],
  [0.1, 'rgb(90,210,40)'],
  [0.3, 'rgb(170,225,30)'],
  [0.5, 'rgb(250,220,0)'],
  [0.68, 'rgb(250,120,0)'],
  [0.8, 'rgb(230,30,30)'],
  [1, 'rgb(230,30,30)'],
];

/** The blurred edge's width, and its blur, by zoom: about a cleared corridor's own width zoomed
 *  out, where a wider one would smudge it, to 14 px close in. */
const FOG_EDGE_WIDTH = ['interpolate', ['exponential', 2], ['zoom'], 10, 1, 13, 5, 15, 14, 18, 20];

/** Each veil is the opposite of the basemap under it: dark ink over a light map, a cream mist over
 *  a dark one or imagery. The Country/Region fills take the same, so nothing shifts at a tier. */
const LIGHT_VEIL = { color: '#202b25', opacity: 0.82 };
const DARK_VEIL = { color: '#f7f4ec', opacity: 0.82 };

/** Heatmap's wash over the basemap, so the heat reads against a quieter map: the veils' pairing,
 *  lightened. Switched by visibility, which MapLibre Native draws again after a hide only from
 *  13.7.1, the version the Android app requires. */
const LIGHT_DIM = { color: '#f7f4ec', opacity: 0.45 };
const DARK_DIM = { color: '#000000', opacity: 0.35 };

/** The borders: the veil's opposite, faint until hovered. */
const LIGHT_BORDER = '#f7f4ec';
const DARK_BORDER = '#202b25';
const BORDER_OPACITY = 0.22;
const BORDER_WIDTH = 0.7;
const HOVER_BORDER_OPACITY = 0.95;
const HOVER_BORDER_WIDTH = 2.5;

/** An outline is hovered while fogPlaces.ts sets its `hover` state. */
const HOVERED = ['boolean', ['feature-state', 'hover'], false];

/** The Country/Region outlines are Overture Maps' divisions, built from OpenStreetMap (IMPLEMENTATION.md §4.2.4). */
const BOUNDARIES_ATTRIBUTION = '<a href="https://overturemaps.org">Overture Maps</a>';

const BORDER_LAYERS = [COUNTRY_BORDER_LAYER, REGION_BORDER_LAYER, PLACE_BORDER_LAYER];
const FOG_LAYERS = [FOG_LAYER, FOG_EDGE_LAYER, ...PLACE_FILL_LAYERS, ...BORDER_LAYERS];

/**
 * The heat circles' radius by zoom: each tile's cells are CELL_PX across at its own zoom and double
 * that one zoom in, until the next zoom's tiles, with cells half the size, take over. Past the
 * last zoom the cells stop shrinking, and the radius keeps growing with them.
 */
export function heatPointsRadius(): unknown[] {
  const r = CELL_PX * RADIUS_PER_CELL;
  const stops: number[] = [];
  for (let z = 0; z < HEAT_POINTS_MAX_ZOOM; z++) stops.push(z, r, z + 0.999, 2 * r);
  stops.push(HEAT_POINTS_MAX_ZOOM, r, HEAT_POINTS_MAX_ZOOM + 9, r * 2 ** 9);
  return ['interpolate', ['exponential', 2], ['zoom'], ...stops];
}

/** One mode's view over a base that reads `dark`. */
export function coverageView(mode: MapMode, dark: boolean): LayerView {
  const veil = dark ? DARK_VEIL : LIGHT_VEIL;
  const dim = dark ? DARK_DIM : LIGHT_DIM;
  const shown = (on: boolean) => ({ visibility: on ? 'visible' : 'none' });
  const fill = { 'fill-color': veil.color, 'fill-opacity': veil.opacity };
  // Every outline is in the tile; the veil covers the unvisited and the sea. A hovered outline
  // thins its veil, or tints a visited one, so the place under the pointer stands out.
  const outlineFill = {
    'fill-color': veil.color,
    'fill-opacity': ['case', ['get', 'visited'], ['case', HOVERED, 0.12, 0], ['case', HOVERED, veil.opacity - 0.14, veil.opacity]],
  };
  const border = {
    // On cleared ground the basemap shows, so a visited outline takes the veil's own ink.
    'line-color': ['case', ['get', 'visited'], veil.color, dark ? DARK_BORDER : LIGHT_BORDER],
    'line-opacity': ['case', HOVERED, HOVER_BORDER_OPACITY, BORDER_OPACITY],
    'line-width': ['case', HOVERED, HOVER_BORDER_WIDTH, BORDER_WIDTH],
  };
  return {
    layout: {
      [HEATMAP_DIM_LAYER]: shown(mode === 'heatmap'),
      ...Object.fromEntries(FOG_LAYERS.map((id) => [id, shown(mode === 'fog')])),
      [HEAT_POINTS_LAYER]: shown(mode === 'heatmap'),
    },
    paint: {
      [HEATMAP_DIM_LAYER]: { 'background-color': dim.color, 'background-opacity': dim.opacity },
      [FOG_LAYER]: fill,
      [FOG_EDGE_LAYER]: { 'line-color': veil.color, 'line-opacity': veil.opacity },
      ...Object.fromEntries(PLACE_FILL_LAYERS.map((id) => [id, outlineFill])),
      ...Object.fromEntries(BORDER_LAYERS.map((id) => [id, border])),
    },
  };
}

/** The `coverage` group over a basemap drawn `dark`. */
export function coverageGroup(dark: boolean, tileVersion: string, lang: string): GroupPart {
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
        [COUNTRY_FOG_SOURCE]: { type: 'vector', tiles: outlines('countries'), minzoom: 0, maxzoom: COUNTRY_MAX_ZOOM, attribution: BOUNDARIES_ATTRIBUTION, promoteId: 'id' },
        [REGION_FOG_SOURCE]: { type: 'vector', tiles: outlines('regions'), minzoom: COUNTRY_MAX_ZOOM, maxzoom: REGION_MAX_ZOOM, attribution: BOUNDARIES_ATTRIBUTION, promoteId: 'id' },
        [PLACE_FOG_SOURCE]: { type: 'vector', tiles: outlines('places'), minzoom: REGION_MAX_ZOOM, maxzoom: PLACE_MAX_ZOOM - 1, attribution: BOUNDARIES_ATTRIBUTION, promoteId: 'id' },
        [HEAT_POINTS_SOURCE]: { type: 'vector', tiles: tilePath('heat-points', tileVersion), minzoom: 0, maxzoom: HEAT_POINTS_MAX_ZOOM },
      },
      layers: [
        layer({ id: HEATMAP_DIM_LAYER, type: 'background' }),
        layer({
          id: FOG_LAYER,
          type: 'fill',
          source: FOG_SOURCE,
          'source-layer': 'fog',
          minzoom: PLACE_MAX_ZOOM,
          filter: ['==', ['get', 'kind'], 'veil'],
        }),
        layer({
          id: FOG_EDGE_LAYER,
          type: 'line',
          source: FOG_SOURCE,
          'source-layer': 'fog',
          minzoom: PLACE_MAX_ZOOM,
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
        layer({
          id: PLACE_FOG_LAYER,
          type: 'fill',
          source: PLACE_FOG_SOURCE,
          'source-layer': 'places',
          minzoom: REGION_MAX_ZOOM,
          maxzoom: PLACE_MAX_ZOOM,
          // Antialiasing drew a hairline where two locked places meet; the borders below draw
          // them on purpose.
          paint: { 'fill-antialias': false },
        }),
        ...([
          [COUNTRY_BORDER_LAYER, COUNTRY_FOG_SOURCE, 'countries', 0, COUNTRY_MAX_ZOOM],
          [REGION_BORDER_LAYER, REGION_FOG_SOURCE, 'regions', COUNTRY_MAX_ZOOM, REGION_MAX_ZOOM],
          [PLACE_BORDER_LAYER, PLACE_FOG_SOURCE, 'places', REGION_MAX_ZOOM, PLACE_MAX_ZOOM],
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
        layer({
          id: HEAT_POINTS_LAYER,
          type: 'heatmap',
          source: HEAT_POINTS_SOURCE,
          'source-layer': 'heat',
          paint: {
            'heatmap-weight': ['get', 'w'],
            'heatmap-intensity': HEAT_POINTS_INTENSITY,
            'heatmap-radius': heatPointsRadius() as never,
            'heatmap-color': ['interpolate', ['linear'], ['heatmap-density'], ...HEAT_RAMP.flat()] as never,
          },
        }),
      ],
    },
    view: (mode, onDark) => coverageView(mode, onDark),
    tiers: [{ tier: 'country', below: COUNTRY_MAX_ZOOM }, { tier: 'region', below: REGION_MAX_ZOOM }, { tier: 'city' }],
  };
}
