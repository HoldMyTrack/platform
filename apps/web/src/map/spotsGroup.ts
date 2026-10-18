import type { ExpressionSpecification, LayerSpecification } from 'maplibre-gl';
import { IMAGES_METADATA, ROLE_METADATA, tilePath, TOGGLE_METADATA, VARS_METADATA, type GroupPart } from './mapLayers.ts';

/**
 * The Spots layers (IMPLEMENTATION.md §4.25, ADR-0021) as the layers document's `spots` group:
 * outdoor places from OpenStreetMap, each a badge over its area, drawn in every map mode for the
 * categories the Layers menu has on. The tiles come from `/tiles/v1/spots`, from SPOTS_MIN_ZOOM;
 * below it, "Show in this area" fills a GeoJSON source of its own.
 *
 * On top of the whole stack rather than beneath the basemap's labels: a spot is something to find
 * on the map, so the fog veil mustn't bury it, and a label crossing it is less of a loss than the
 * icon. Fog's label dimming leaves the badges alone, since the views don't list them.
 *
 * The client binds the categories shown, the ids the account captured (FR-15.6) and capture
 * mode's target (`apps/android/docs/SPEC.md` FR-2.8) as vars, and draws each badge image the
 * layers name in the colors given: the icon shapes are the client's.
 */

/** The server sends nothing below it (internal/httpapi's spotsMinZoom). */
export const SPOTS_MIN_ZOOM = 13;
/** The lowest zoom "Show in this area" (ShowInArea.tsx) offers places at, where a screen is about a
 *  metro area (~100 km across). Below it a view spans a state or more, where the dense categories
 *  run into the request's cap and the rest are too small to tell apart. */
export const SPOTS_IN_AREA_MIN_ZOOM = 10;
/** Past it the tiles serve every zoom above by overzooming, as the tracks tiles do past z14. */
const SPOTS_MAX_ZOOM = 14;

export const SPOTS_LAYER_ID = 'spots-icons';
export const SPOTS_IN_AREA_LAYER_ID = 'spots-in-area-icons';
export const SPOTS_IN_AREA_SOURCE_ID = 'spots-in-area';

/** Every category, in the order the Layers menu lists them. */
export const SPOT_CATEGORY_WIRE = ['playground', 'dog_park', 'monument', 'viewpoint', 'history'] as const;

// The marker: a round badge, the category icon in ink on white, ringed in the accent — or, for a
// place the account has captured, white on the accent, ringed darker. Fixed colors, not the
// theme's: the badge carries its own background, so it reads the same on either basemap.
const INK = '#202b25'; // --fm-ink
const ACCENT = '#b07e2e'; // --fm-accent
const ACCENT_DARK = '#7d5820';
const WHITE = '#ffffff';

/** The areas' fill: faint normally, darker in capture mode, darkest for its target. */
const AREA_OPACITY = 0.15;
const CAPTURING_AREA_OPACITY = 0.35;
const TARGET_AREA_OPACITY = 0.55;

const byCategory: ExpressionSpecification = ['in', ['get', 'category'], ['var', 'spotCategories']];
const isCaptured: ExpressionSpecification = ['in', ['to-number', ['get', 'id']], ['var', 'captured']];
const isTarget: ExpressionSpecification = ['==', ['to-number', ['get', 'id']], ['var', 'captureTarget']];
// The tiles' layers leave out a retired place (docs/SPEC.md FR-15.1) unless the account captured
// it; "Show in this area" gets only those from the server already.
const shown: ExpressionSpecification = ['all', byCategory, ['any', ['!', ['to-boolean', ['get', 'retired']]], isCaptured]];

/** The badge image's name, the client registers each under it in the colors given. */
function images(): Record<string, { category: string; fill: string; ring: string; ink: string }> {
  return Object.fromEntries(
    SPOT_CATEGORY_WIRE.flatMap((category) => [
      [`spot-${category}`, { category, fill: WHITE, ring: ACCENT, ink: INK }],
      [`spot-${category}-captured`, { category, fill: ACCENT, ring: ACCENT_DARK, ink: WHITE }],
    ]),
  );
}

/** The areas' edge, 1 at SPOTS_MIN_ZOOM to 2 at 17, doubled for capture mode's target. */
function edgeWidth(): unknown[] {
  const width = (base: number) => ['case', isTarget, base * 2, base];
  return ['interpolate', ['linear'], ['zoom'], SPOTS_MIN_ZOOM, width(1), 17, width(2)];
}

function badges(id: string, source: string, sourceLayer: string | undefined, minzoom: number, maxzoom: number, filter: ExpressionSpecification, filterVars: string[]): LayerSpecification {
  return {
    id,
    type: 'symbol',
    source,
    ...(sourceLayer && { 'source-layer': sourceLayer }),
    minzoom,
    maxzoom,
    filter,
    layout: {
      visibility: 'none',
      'icon-image': ['case', isCaptured, ['concat', 'spot-', ['get', 'category'], '-captured'], ['concat', 'spot-', ['get', 'category']]],
      // Every spot is drawn, however close to another: a hidden playground is a missed one.
      'icon-allow-overlap': true,
      'icon-ignore-placement': true,
    },
    metadata: { [TOGGLE_METADATA]: 'spots', [VARS_METADATA]: { filter: filterVars, 'icon-image': ['captured'] }, [IMAGES_METADATA]: images() },
  } as LayerSpecification;
}

/**
 * Bottom to top: every area's fill, the outlines, the circles' dashed edges, "Show in this area"'s
 * badges, the tiles' badges. The two badge layers never overlap: one stops where the other starts,
 * at SPOTS_MIN_ZOOM. Two line layers because a dash pattern can't vary per feature: the place's own
 * OSM outline solid, the 30 m circle standing in for a place mapped as a point dashed.
 */
export function spotsGroup(tileVersion: string): GroupPart {
  const area = (id: string, type: 'fill' | 'line', filter: ExpressionSpecification, paint: Record<string, unknown>, dashed = false): LayerSpecification =>
    ({
      id,
      type,
      source: 'spots',
      'source-layer': 'spot_areas',
      minzoom: SPOTS_MIN_ZOOM,
      filter,
      layout: { visibility: 'none', ...(type === 'line' && { 'line-join': 'round' }) },
      paint: { ...paint, ...(dashed && { 'line-dasharray': ['literal', [2, 2]] }) },
      metadata: {
        [TOGGLE_METADATA]: 'spots',
        [VARS_METADATA]: { filter: ['spotCategories', 'captured'], [type === 'fill' ? 'fill-opacity' : 'line-width']: ['captureTarget'] },
        // Android's capture guide draws in the areas' color.
        ...(id === 'spots-area-line' && { [ROLE_METADATA]: 'spot-area' }),
      },
    }) as LayerSpecification;
  return {
    group: {
      id: 'spots',
      placement: 'top',
      sources: {
        spots: { type: 'vector', tiles: tilePath('spots', tileVersion), minzoom: SPOTS_MIN_ZOOM, maxzoom: SPOTS_MAX_ZOOM },
        [SPOTS_IN_AREA_SOURCE_ID]: { type: 'geojson' },
      },
      layers: [
        area('spots-area-fill', 'fill', shown, {
          'fill-color': ACCENT,
          'fill-opacity': ['case', ['==', ['var', 'captureTarget'], -1], AREA_OPACITY, isTarget, TARGET_AREA_OPACITY, CAPTURING_AREA_OPACITY],
        }),
        area('spots-area-line', 'line', ['all', ['!', ['to-boolean', ['get', 'circle']]], shown], { 'line-color': ACCENT, 'line-width': edgeWidth() }),
        area('spots-circle-line', 'line', ['all', ['to-boolean', ['get', 'circle']], shown], { 'line-color': ACCENT, 'line-width': edgeWidth() }, true),
        badges(SPOTS_IN_AREA_LAYER_ID, SPOTS_IN_AREA_SOURCE_ID, undefined, SPOTS_IN_AREA_MIN_ZOOM, SPOTS_MIN_ZOOM, byCategory, ['spotCategories']),
        badges(SPOTS_LAYER_ID, 'spots', 'spots', SPOTS_MIN_ZOOM, 24, shown, ['spotCategories', 'captured']),
      ],
    },
    view: () => ({ layout: {}, paint: {} }),
    vars: { spotCategories: [], captured: [], captureTarget: -1 },
  };
}
