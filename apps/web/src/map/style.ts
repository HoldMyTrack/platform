import { layers, namedFlavor } from '@protomaps/basemaps';
import type {
  FilterSpecification,
  LayerSpecification,
  LineLayerSpecification,
  RasterSourceSpecification,
  StyleSpecification,
} from 'maplibre-gl';
import { GLYPHS_PATH, PMTILES_PATH, SPRITE_BASE_PATH } from './config';
import { globeProjection } from './globe';
import { PATH_COLORS, pathDash, PATHS_MIN_ZOOM } from './pathColors.ts';
import { roadLayerIds } from './roads';

/**
 * Style construction, kept pure and DOM-free on purpose.
 *
 * This module must not touch React, `window`, or a live Map. It is the seam the
 * print pipeline needs: the same function has to run headlessly server-side to
 * render an identical map at print DPI (IMPLEMENTATION.md §5.5).
 * Anything browser-shaped added here breaks that without breaking the app, which
 * is the worst kind of regression, so the rule is worth keeping strictly — hence
 * `origin` being a parameter rather than a `window.location` read.
 */

/** Flavors shipped by @protomaps/basemaps 5.7.2, each with a matching sprite sheet. */
export const FLAVORS = ['light', 'dark', 'white', 'black', 'grayscale'] as const;
export type Flavor = (typeof FLAVORS)[number];

export function isFlavor(value: string): value is Flavor {
  return (FLAVORS as readonly string[]).includes(value);
}

/** The flavors drawn light-on-dark — the ones the cream fog veil and the export watermark's
 *  light colors are for. */
export function isDarkFlavor(flavor: Flavor): boolean {
  return flavor === 'dark' || flavor === 'black';
}

/** The flavors drawn light-on-dark, or satellite imagery under any flavor: it reads dark, so it
 *  gets the same watermark colors a dark flavor does, as the layers' satellite views take the
 *  dark veil (mapLayers.ts, docs/SPEC.md FR-4.14). */
export function isDarkBase(flavor: Flavor, satellite: boolean): boolean {
  return satellite || isDarkFlavor(flavor);
}

/** The source id every basemap layer is bound to; fog and track layers will not reuse it. */
export const BASEMAP_SOURCE = 'protomaps';

/** The style `metadata` key holding the build it came from, which the layers document carries
 *  too (mapLayers.ts): a client holding the two from different builds fetches the style again. */
export const STYLE_BUILD_METADATA = 'holdmytrack:style-build';

/**
 * Satellite mode (docs/SPEC.md FR-4.14): a raster imagery source under the vector basemap's
 * roads, boundaries and labels. The imagery is a deployment's choice, not the style's — a tile
 * URL template carrying its own key, and the credit its terms require — so it is an option here
 * and absent from the style entirely when a deployment configures none.
 */
export interface SatelliteSource {
  /** An XYZ template, `{z}/{x}/{y}`, key included. */
  tiles: string;
  /** The provider's tile edge in pixels. MapTiler's are 512: declaring them 256 would draw each
   *  one at half size and fetch four times as many, all counted against the quota. */
  tileSize: number;
  /** The deepest zoom the provider serves; MapLibre overzooms past it. */
  maxzoom: number;
  /** HTML, like `ATTRIBUTION`: shown by the attribution control and baked into exports. */
  attribution: string;
}

/** The source and layer id of the imagery. Android toggles it by name (`MapSatellite`). */
export const SATELLITE_SOURCE = 'satellite';
export const SATELLITE_LAYER_ID = 'satellite';

/** The style `metadata` key listing the layers satellite mode hides, for clients that toggle it
 *  from the served document rather than from this module (Android's `MapSatellite`). */
export const SATELLITE_HIDES_METADATA = 'holdmytrack:satellite-hides';

/** The style `metadata` keys naming the road layers satellite mode dims, and to what opacity —
 *  read from the style rather than re-derived, since a dimmed layer no longer looks undimmed. */
export const SATELLITE_DIMS_METADATA = 'holdmytrack:satellite-dims';
export const SATELLITE_ROAD_OPACITY_METADATA = 'holdmytrack:satellite-road-opacity';

/** The style `metadata` key listing the road layers the Layers menu's Roads shows and hides
 *  (roads.ts), for Android's `MapRoads` to read rather than re-derive. In every style, imagery
 *  or not, so the server keeps it (it strips only `holdmytrack:satellite-*`). */
export const ROADS_METADATA = 'holdmytrack:roads';

/** Over imagery the roads are drawn see-through, so they mark the way without painting over the
 *  ground they cross — the flavors' road colors are made for a flat background, not a photo. */
export const SATELLITE_ROAD_OPACITY = 0.4;

/**
 * The road lines satellite mode dims to `SATELLITE_ROAD_OPACITY`: the basemap's `roads_*` line
 * layers, casings included, that set no opacity of their own. That leaves out rail (already
 * half-transparent, and not a road), so switching back only has to reset the rest to the
 * default. The trail and track layers stay opaque: on satellite imagery they're what the
 * ground can't show.
 */
export function satelliteDimmedLayerIds(style: readonly LayerSpecification[]): string[] {
  return style
    .filter(
      (layer) =>
        layer.type === 'line' &&
        layer.source === BASEMAP_SOURCE &&
        layer.id.startsWith('roads_') &&
        layer.paint?.['line-opacity'] === undefined,
    )
    .map((layer) => layer.id);
}

/**
 * The layers satellite mode hides so the imagery shows through: the basemap's background and
 * area fills (earth, water, landuse, landcover, buildings). Roads, boundaries and labels stay —
 * that is the hybrid. Derived from layer type rather than listed by id, so a
 * `@protomaps/basemaps` upgrade that adds a fill doesn't paint over the imagery.
 */
export function satelliteHiddenLayerIds(style: readonly LayerSpecification[]): string[] {
  return style
    .filter((layer) => layer.type === 'background' || (layer.type === 'fill' && layer.source === BASEMAP_SOURCE))
    .map((layer) => layer.id);
}

/**
 * Mandatory attribution, not decoration: the Protomaps basemap is an ODbL
 * "Produced Work", so OSM credit has to be visible on the map and on any export.
 */
export const ATTRIBUTION =
  '<a href="https://protomaps.com">Protomaps</a> © <a href="https://openstreetmap.org">OpenStreetMap</a>';

/** Plain-text form of `ATTRIBUTION` — derived, not hand-duplicated, so the two can never say
 *  different things. `AttributionControl` renders the HTML above as a DOM overlay, which is
 *  fine for the live map but invisible to anything that reads pixels off a canvas instead
 *  (`exportMap.ts`'s PNG export bakes this string into the raster itself for exactly that
 *  reason — canvas `fillText` takes a plain string, not markup). */
export const ATTRIBUTION_TEXT = ATTRIBUTION.replace(/<[^>]+>/g, '');

export interface BuildStyleOptions {
  flavor: Flavor;
  /** Absolute origin, e.g. `https://cdn.example.com` — no trailing slash. */
  origin: string;
  /** Label language. Protomaps carries per-language name fields in the `places` layer. */
  lang?: string;
  pmtilesPath?: string;
  glyphsPath?: string;
  spriteBasePath?: string;
  /** The deployment's imagery, or none: then the style has no satellite source at all. */
  satellite?: SatelliteSource | null;
  /** Whether satellite mode starts on. Ignored without `satellite`. */
  satelliteOn?: boolean;
  /** A globe while zoomed out (GLOBE_MAX_ZOOM), flat from there in. Only the web's own maps:
   *  the style served to Android leaves it out, since MapLibre Native has no globe. */
  globe?: boolean;
}

/** Sidewalks, crossings, steps and pedestrian areas stay on the stock grey on purpose: in a
 *  city they outnumber real paths and would bury them. Tracks — OSM's `highway=track`, dirt,
 *  farm and forest roads — are their own layer: vehicle-width, often the very thing a rider
 *  looks for or avoids, and where OSM maps every field and forestry road (much of Europe) far
 *  more of them than trails. */
const TRAIL_DETAILS = ['path', 'footway', 'bridleway'];
const TRACK_DETAIL = 'track';

function pathLayers(flavor: Flavor, bridges: boolean): LineLayerSpecification[] {
  const colors = PATH_COLORS[flavor];
  // Legacy filter syntax, the same as the stock road layers use.
  const structure = bridges ? [['has', 'is_bridge']] : [['!has', 'is_tunnel'], ['!has', 'is_bridge']];
  const filter = (detail: unknown[]) =>
    ['all', ...structure, ['==', 'kind', 'path'], detail] as unknown as FilterSpecification;
  const prefix = bridges ? 'paths_bridges_' : 'paths_';
  // Tracks first, so a trail sharing a stretch with one draws over it.
  return [
    {
      id: `${prefix}track`,
      type: 'line',
      source: BASEMAP_SOURCE,
      'source-layer': 'roads',
      minzoom: PATHS_MIN_ZOOM,
      filter: filter(['==', 'kind_detail', TRACK_DETAIL]),
      paint: {
        'line-color': colors.track,
        // Longer dashes and a wider line than a trail: a road a vehicle fits on.
        'line-dasharray': pathDash(flavor, 'track') ?? [],
        'line-width': ['interpolate', ['exponential', 1.6], ['zoom'], PATHS_MIN_ZOOM, 1.5, 18, 4],
      },
    },
    {
      id: `${prefix}trail`,
      type: 'line',
      source: BASEMAP_SOURCE,
      'source-layer': 'roads',
      minzoom: PATHS_MIN_ZOOM,
      filter: filter(['in', 'kind_detail', ...TRAIL_DETAILS]),
      paint: {
        'line-color': colors.trail,
        'line-dasharray': pathDash(flavor, 'trail') ?? [],
        'line-width': ['interpolate', ['exponential', 1.6], ['zoom'], PATHS_MIN_ZOOM, 1.3, 18, 3.5],
      },
    },
  ];
}

/** Stock layers with the path layers spliced in right after the one that draws the same
 *  features, so bridges, casings and labels keep stacking over them as they did. */
function withPathLayers(base: LayerSpecification[], flavor: Flavor): LayerSpecification[] {
  return base.flatMap((layer) => {
    if (layer.id === 'roads_other') return [layer, ...pathLayers(flavor, false)];
    if (layer.id === 'roads_bridges_other') return [layer, ...pathLayers(flavor, true)];
    return [layer];
  });
}

function basemapLayers(flavor: Flavor, lang: string): LayerSpecification[] {
  return withPathLayers(layers(BASEMAP_SOURCE, namedFlavor(flavor), { lang }), flavor);
}

/** The basemap's label layers, the same ids in every language: what Fog mutes (mapLayers.ts). */
export function basemapLabelIds(flavor: Flavor): string[] {
  return basemapLayers(flavor, 'en')
    .filter((layer) => layer.type === 'symbol')
    .map((layer) => layer.id);
}

export function buildStyle(options: BuildStyleOptions): StyleSpecification {
  const {
    flavor,
    origin,
    lang = 'en',
    pmtilesPath = PMTILES_PATH,
    glyphsPath = GLYPHS_PATH,
    spriteBasePath = SPRITE_BASE_PATH,
    satellite = null,
    satelliteOn = false,
    globe = false,
  } = options;

  const base = origin.replace(/\/$/, '');
  const vector = basemapLayers(flavor, lang);
  const hidden = satellite ? satelliteHiddenLayerIds(vector) : [];
  const dimmed = satellite ? satelliteDimmedLayerIds(vector) : [];

  return {
    version: 8,
    glyphs: `${base}${glyphsPath}`,
    // One sheet per flavor; MapLibre appends `.json`/`.png` and picks @2x itself.
    // Must be absolute: MapLibre 6 throws on a relative sprite URL.
    sprite: `${base}${spriteBasePath}/${flavor}`,
    sources: {
      // `url` (not `tiles`) lets the pmtiles Protocol answer with TileJSON built
      // from the archive header, so MapLibre learns the real bounds and zoom
      // range and never requests a tile the archive cannot contain.
      [BASEMAP_SOURCE]: {
        type: 'vector',
        url: `pmtiles://${base}${pmtilesPath}`,
        attribution: ATTRIBUTION,
      },
      ...(satellite && { [SATELLITE_SOURCE]: satelliteSourceSpec(satellite) }),
    },
    metadata: {
      [ROADS_METADATA]: roadLayerIds(vector, BASEMAP_SOURCE),
      ...(satellite && {
        [SATELLITE_HIDES_METADATA]: hidden,
        [SATELLITE_DIMS_METADATA]: dimmed,
        [SATELLITE_ROAD_OPACITY_METADATA]: SATELLITE_ROAD_OPACITY,
      }),
    },
    layers: satellite ? withSatelliteLayer(vector, hidden, dimmed, satelliteOn) : vector,
    ...(globe && { projection: globeProjection() }),
  };
}

function satelliteSourceSpec(satellite: SatelliteSource): RasterSourceSpecification {
  return {
    type: 'raster',
    tiles: [satellite.tiles],
    tileSize: satellite.tileSize,
    maxzoom: satellite.maxzoom,
    attribution: satellite.attribution,
  };
}

/** The imagery right above the background, so everything the vector basemap draws after it —
 *  and every layer group inserted at the first symbol layer — stacks over it. */
function withSatelliteLayer(
  base: LayerSpecification[],
  hidden: string[],
  dimmed: string[],
  on: boolean,
): LayerSpecification[] {
  const imagery: LayerSpecification = {
    id: SATELLITE_LAYER_ID,
    type: 'raster',
    source: SATELLITE_SOURCE,
    layout: { visibility: on ? 'visible' : 'none' },
  };
  const hide = new Set(on ? hidden : []);
  const dim = new Set(on ? dimmed : []);
  const layers = base.map((layer) => {
    if (hide.has(layer.id)) return { ...layer, layout: { ...layer.layout, visibility: 'none' } } as LayerSpecification;
    if (dim.has(layer.id)) return { ...layer, paint: { ...layer.paint, 'line-opacity': SATELLITE_ROAD_OPACITY } } as LayerSpecification;
    return layer;
  });
  const at = layers.findIndex((layer) => layer.type === 'background') + 1;
  return [...layers.slice(0, at), imagery, ...layers.slice(at)];
}
