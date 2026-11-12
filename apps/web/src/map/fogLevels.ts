/**
 * Fog's levels (IMPLEMENTATION.md §4.2.4): which is in view, and what picking one in the level
 * control does. Each level draws at every zoom; its band, from the layers document, is where it
 * draws by default. Shared cases: testdata/client-rules/fog-level-*.json.
 */

/** A level and its band: from `from` (0 when absent) up to but not including `below` (no end
 *  when absent). */
export interface FogLevelBand {
  level: string;
  from?: number;
  below?: number;
}

/** What a level is when nothing else is: the finest, drawing every track. */
export const EXACT = 'exact';

/** The level in view: the locked one, else the one whose band holds `zoom`. */
export function fogLevelInView(levels: readonly FogLevelBand[], zoom: number, locked: string | null = null): string {
  if (locked !== null && levels.some((l) => l.level === locked)) return locked;
  const inBand = levels.find((l) => zoom >= (l.from ?? 0) && (l.below === undefined || zoom < l.below));
  return inBand?.level ?? levels.at(-1)?.level ?? EXACT;
}

/** Picking `picked` while `locked` is locked at `zoom`: the lock after it, and the zoom to move
 *  the camera out to, keeping its centre, or null to stay. Picking never zooms in: a level
 *  further in draws where the camera is. */
export function fogLevelPick(
  levels: readonly FogLevelBand[],
  zoom: number,
  locked: string | null,
  picked: string,
): { locked: string | null; zoom: number | null } {
  const band = levels.find((l) => l.level === picked);
  if (!band) return { locked, zoom: null };
  if (picked === locked) return { locked: null, zoom: null };
  if (band.below !== undefined && zoom >= band.below) return { locked: picked, zoom: band.below };
  return { locked: picked, zoom: null };
}

/** The highest zoom a layer can have: a range starting there never draws. */
const MAX_ZOOM = 24;

/** A level with the layers that draw it (the layers document's `levels`). */
export interface FogLevelLayers extends FogLevelBand {
  layers: readonly string[];
}

/** Each level's layers' zoom range: its band, or with a level locked, every zoom for its layers
 *  and none for the others'. */
export function levelZoomRanges(levels: readonly FogLevelLayers[], locked: string | null): Record<string, [number, number]> {
  const lock = levels.some((l) => l.level === locked) ? locked : null;
  const ranges: Record<string, [number, number]> = {};
  for (const l of levels) {
    const range: [number, number] = lock === null ? [l.from ?? 0, l.below ?? MAX_ZOOM] : l.level === lock ? [0, MAX_ZOOM] : [MAX_ZOOM, MAX_ZOOM];
    for (const id of l.layers) ranges[id] = range;
  }
  return ranges;
}

/** The catalog key naming a level in the control: what the account's country calls its places
 *  (`word`, a local_type the tooltip's kinds name) where the catalog has a word for it, else the
 *  generic name. */
export function levelLabelKey(level: string, word: string | undefined, has: (key: string) => boolean): string {
  const own = word ? `map.fog.type.${word}` : '';
  if ((level === 'region' || level === 'county') && has(own)) return own;
  return `map.fog.level.${level}`;
}

/** How many places of `level` the account has explored (the coverage status's `explored`), or
 *  null for a level that counts none: exact coverage. */
export function exploredCount(explored: { countries: number; regions: number; counties: number; cities: number }, level: string): number | null {
  const by: Record<string, number> = { country: explored.countries, region: explored.regions, county: explored.counties, city: explored.cities };
  return by[level] ?? null;
}
