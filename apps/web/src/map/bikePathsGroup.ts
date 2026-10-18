import type { LayerSpecification } from 'maplibre-gl';
import { tilePath, TOGGLE_METADATA, type GroupPart, type LegendEntry } from './mapLayers.ts';
import { PATH_COLORS, PATH_LAYER_IDS, pathDash } from './pathColors.ts';
import type { Flavor } from './style';

/**
 * The Layers menu's Bike paths, Shared paths and Mountain bike trails (docs/SPEC.md FR-4.13,
 * IMPLEMENTATION.md §4.24) as the layers document's `bike-paths` group: OpenStreetMap's
 * cycleways, bike-designated paths and singletrack from `/tiles/v1/bike-paths`, not the basemap,
 * which has none below zoom 13. Drawn from zoom 9, so a whole region's bike network shows at once.
 *
 * The group lifts the basemap's trail and track layers to its place, over Fog's veil and
 * Heatmap's heat, and draws the bike kinds over them and under the rider's own tracks: under the
 * veil, unridden paths showed at a fifth of their colour.
 */

/** Where the tiles start (internal/httpapi's bikePathsMinZoom): a region on the screen. */
export const BIKE_PATHS_MIN_ZOOM = 9;
/** Past it the tiles serve every zoom above by overzooming, like the spots tiles. */
const BIKE_PATHS_MAX_ZOOM = 14;
/** internal/httpapi's ST_AsMVT layer name. */
const BIKE_PATHS_SOURCE_LAYER = 'bike_paths';
const SOURCE = 'bike-paths';

/** The Layers menu switches, by TOGGLE_METADATA name. */
export type BikePathToggle = 'bikePaths' | 'sharedPaths' | 'mtbTrails';

/** Which of the three are showing. */
export type BikePathOverlays = Record<BikePathToggle, boolean>;

function width(atMin: number, at13: number, at18: number): unknown[] {
  return ['interpolate', ['exponential', 1.6], ['zoom'], BIKE_PATHS_MIN_ZOOM, atMin, 13, at13, 18, at18];
}

function line(id: string, kind: string, toggle: BikePathToggle, color: string, dash: number[] | undefined, lineWidth: unknown[], round: boolean): LayerSpecification {
  return {
    id,
    type: 'line',
    source: SOURCE,
    'source-layer': BIKE_PATHS_SOURCE_LAYER,
    minzoom: BIKE_PATHS_MIN_ZOOM,
    filter: ['==', ['get', 'kind'], kind],
    layout: { visibility: 'none', ...(round && { 'line-cap': 'round', 'line-join': 'round' }) },
    paint: {
      'line-color': color,
      // Told from a cycleway by its hue, or on a monochrome flavor by a dash (pathColors.ts).
      ...(dash && { 'line-dasharray': ['literal', dash] }),
      'line-width': lineWidth as never,
    },
    metadata: { [TOGGLE_METADATA]: toggle },
  } as LayerSpecification;
}

/** The legend line for `kind`. */
function legend(flavor: Flavor, kind: keyof (typeof PATH_COLORS)[Flavor]): LegendEntry {
  const dash = pathDash(flavor, kind);
  return { color: PATH_COLORS[flavor][kind], ...(dash && { dash }) };
}

/** Bottom to top mountain-bike trails, shared paths and cycleways, the likelier route on top
 *  where two meet. */
export function bikePathsGroup(flavor: Flavor, tileVersion: string): GroupPart {
  const colors = PATH_COLORS[flavor];
  return {
    group: {
      id: 'bike-paths',
      placement: 'beneath-labels',
      lifts: [...PATH_LAYER_IDS],
      sources: { [SOURCE]: { type: 'vector', tiles: tilePath('bike-paths', tileVersion), minzoom: BIKE_PATHS_MIN_ZOOM, maxzoom: BIKE_PATHS_MAX_ZOOM } },
      layers: [
        line('bike-paths-mtb', 'mtb', 'mtbTrails', colors.mtb, pathDash(flavor, 'mtb'), width(1.5, 2, 4.5), true),
        line('bike-paths-shared', 'shared', 'sharedPaths', colors.shared, pathDash(flavor, 'shared'), width(1.5, 2, 4.5), false),
        line('bike-paths-cycleway', 'cycleway', 'bikePaths', colors.cycleway, undefined, width(1.8, 2.4, 5.5), true),
      ],
      legend: {
        bikePaths: legend(flavor, 'cycleway'),
        sharedPaths: legend(flavor, 'shared'),
        mtbTrails: legend(flavor, 'mtb'),
        trails: legend(flavor, 'trail'),
        tracks: legend(flavor, 'track'),
      },
    },
    view: () => ({ layout: {}, paint: {} }),
  };
}
