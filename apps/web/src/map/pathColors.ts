import type { Flavor } from './style';

/**
 * The trail and track layers (docs/SPEC.md FR-4.13), part of the map itself rather than the
 * Layers menu. Protomaps already carries every OSM path in the `roads` layer (`kind=path`,
 * sorted by `kind_detail`), but the stock style draws them all through `roads_other` as one
 * hairline grey from z14, which reads as no paths at all. These draw trails and tracks over that
 * same geometry from further out. The layers document's bike-paths group lifts them over Fog's
 * veil by id (bikePathsGroup.ts), so the ids are part of the served style's contract.
 */
export const PATH_LAYER_IDS = ['paths_trail', 'paths_track', 'paths_bridges_trail', 'paths_bridges_track'] as const;

/** The zoom the trail and track layers start at: the first the basemap carries tracks at. It
 *  has trails only from z13, so they join a zoom later. Bike and shared paths start further out,
 *  from their own tiles (bikePathsGroup.ts). */
export const PATHS_MIN_ZOOM = 12;

/** Blue for cycleways, teal for shared paths, purple for mountain-bike trails (bikePathsGroup.ts),
 *  green for trails, brown for tracks, all clear of the ochre activity tracks (tracks.ts). Teal sits between the cycleway blue and
 *  the trail green, so a shared path reads as a bike route people walk too, and the hue alone
 *  tells it from a cycleway when the map is zoomed out too far for a dash to show. On the light
 *  flavors the two bike colors are dark enough to hold up on Fog's grey veil; on the dark ones
 *  they stay bright against the dark map. The monochrome flavors stay monochrome; there the
 *  kinds differ by weight and dash. */
export const PATH_COLORS: Record<Flavor, { cycleway: string; shared: string; mtb: string; trail: string; track: string }> = {
  light: { cycleway: '#0b5a85', shared: '#0b7f74', mtb: '#7d3a96', trail: '#4f7a3a', track: '#8a5a2b' },
  dark: { cycleway: '#5cbfe0', shared: '#4fd6c2', mtb: '#d29bef', trail: '#8fbf6a', track: '#c9955e' },
  white: { cycleway: '#262626', shared: '#404040', mtb: '#333333', trail: '#6e6e6e', track: '#5c5c5c' },
  grayscale: { cycleway: '#1f1f1f', shared: '#383838', mtb: '#2b2b2b', trail: '#666666', track: '#555555' },
  black: { cycleway: '#c4c4c4', shared: '#a8a8a8', mtb: '#b8b8b8', trail: '#9a9a9a', track: '#b0b0b0' },
};

/** Each kind's dash, in line widths as MapLibre's `line-dasharray` takes it, or none for a solid
 *  line: the map's layers and the Layers menu's legend (the bike-paths group's) both draw from it.
 *  Shared paths and mountain-bike trails are solid in every flavor but the monochrome ones, where
 *  only a dash tells them from a cycleway. */
export function pathDash(flavor: Flavor, kind: keyof (typeof PATH_COLORS)[Flavor]): number[] | undefined {
  switch (kind) {
    case 'cycleway':
      return undefined;
    case 'shared':
      return isMonochrome(flavor) ? [2, 1] : undefined;
    case 'mtb':
      return isMonochrome(flavor) ? [1, 1] : undefined;
    case 'trail':
      return [2, 1];
    case 'track':
      return [3, 1.5];
  }
}

function isMonochrome(flavor: Flavor): boolean {
  return flavor === 'white' || flavor === 'grayscale' || flavor === 'black';
}
