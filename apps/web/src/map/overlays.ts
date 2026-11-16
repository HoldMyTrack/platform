import type { SpotCategory } from './spots';
// spotsGroup.ts, not spots.ts, which pulls in React and MapLibre: tests read this file in Node.
import { SPOT_CATEGORY_WIRE } from './spotsGroup.ts';

/**
 * The map's view choices beside the mode toggle: satellite imagery (the Satellite button,
 * FR-4.10); what the Layers menu (OverlaysMenu.tsx) has picked, the basemap's roads (FR-4.13), bike
 * and shared paths and mountain-bike trails (FR-4.9); and what the Places menu (PlacesMenu.tsx)
 * has, each Spots category (FR-14.2). Each menu's button has a checkbox that shows or hides all of
 * its picks at once. A per-browser view preference, kept in localStorage like the theme, not on
 * the account; roads on and every path and place off until picked.
 */
export interface Overlays {
  /** Satellite imagery under the basemap's roads and labels. Only meaningful when the
   *  deployment configures imagery (config.ts's satelliteSource). */
  satellite: boolean;
  /** The basemap's roads (roads.ts), on until unpicked. */
  roads: boolean;
  /** The Layers checkbox: roads and paths are drawn only while it's on, and kept while it's off. */
  enabled: boolean;
  /** Cycleways, from the bike-path tiles (bikePaths.ts). */
  bikePaths: boolean;
  /** Paths, footways and bridleways designated for bikes, from the same tiles. */
  sharedPaths: boolean;
  /** Singletrack, rated for mountain bikes or of rough ground, from the same tiles. */
  mtbTrails: boolean;
  /** The Places checkbox: the Spots categories are drawn only while it's on, and kept while it's off. */
  placesEnabled: boolean;
  /** The Spots categories shown, in SPOT_CATEGORIES order. */
  spots: SpotCategory[];
}

const STORAGE_KEY = 'hmt.overlays';
// The two toggles the menu replaced: one for the paths (now Bike paths), one for every category.
const LEGACY_PATHS_KEY = 'hmt.showPaths';
const LEGACY_POI_KEY = 'hmt.showPoi';

export const NO_OVERLAYS: Overlays = { satellite: false, roads: true, enabled: true, bikePaths: false, sharedPaths: false, mtbTrails: false, placesEnabled: true, spots: [] };

/** How many roads and paths are picked, whether or not the Layers checkbox is on. */
export function layersCount(overlays: Overlays): number {
  return Number(overlays.roads) + Number(overlays.bikePaths) + Number(overlays.sharedPaths) + Number(overlays.mtbTrails);
}

export type LayerPick = 'roads' | 'bikePaths' | 'sharedPaths' | 'mtbTrails';

/** `overlays` with a road or path ticked or unticked. Ticking one turns the Layers checkbox back on, or the pick would seem to do nothing. */
export function toggleLayer(overlays: Overlays, pick: LayerPick): Overlays {
  const on = !overlays[pick];
  return { ...overlays, [pick]: on, enabled: on || overlays.enabled };
}

/** `overlays` with a Spots category ticked or unticked, kept in SPOT_CATEGORY_WIRE order. Ticking one turns the Places checkbox back on. */
export function togglePlace(overlays: Overlays, category: SpotCategory): Overlays {
  const on = !overlays.spots.includes(category);
  const spots = SPOT_CATEGORY_WIRE.filter((c) => (c === category ? on : overlays.spots.includes(c)));
  return { ...overlays, spots, placesEnabled: on || overlays.placesEnabled };
}

/**
 * The choice `raw`, the stored record, says, else the two toggles before the Layers menu
 * (`legacyPaths`, `legacyPoi`). A record that doesn't parse is the default.
 */
export function readOverlays(raw: string | null, legacyPaths: boolean, legacyPoi: boolean): Overlays {
  if (!raw) return { ...NO_OVERLAYS, bikePaths: legacyPaths, spots: legacyPoi ? [...SPOT_CATEGORY_WIRE] : [] };
  try {
    const saved = JSON.parse(raw) as Partial<Overlays> | null;
    if (saved === null || typeof saved !== 'object') return NO_OVERLAYS;
    // On unless turned off: a choice saved before the checkbox existed keeps showing its picks.
    const enabled = saved.enabled !== false;
    return {
      satellite: saved.satellite === true,
      roads: saved.roads !== false,
      enabled,
      bikePaths: saved.bikePaths === true,
      sharedPaths: saved.sharedPaths === true,
      mtbTrails: saved.mtbTrails === true,
      // Places had no checkbox of its own before the menus split: it takes the one that hid them.
      placesEnabled: typeof saved.placesEnabled === 'boolean' ? saved.placesEnabled : enabled,
      spots: SPOT_CATEGORY_WIRE.filter((c) => Array.isArray(saved.spots) && saved.spots.includes(c)),
    };
  } catch {
    return NO_OVERLAYS;
  }
}

export function loadOverlays(): Overlays {
  try {
    const storage = window.localStorage;
    return readOverlays(storage.getItem(STORAGE_KEY), storage.getItem(LEGACY_PATHS_KEY) === '1', storage.getItem(LEGACY_POI_KEY) === '1');
  } catch {
    return NO_OVERLAYS;
  }
}

export function saveOverlays(overlays: Overlays): void {
  try {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(overlays));
    window.localStorage.removeItem(LEGACY_PATHS_KEY);
    window.localStorage.removeItem(LEGACY_POI_KEY);
  } catch {
    // Storage blocked (private mode, disabled site data): the menu still works for this page.
  }
}
