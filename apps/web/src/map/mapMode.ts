import type { Map as MapLibreMap } from 'maplibre-gl';
import { setHiddenGroups, updateLayers } from './applyLayers.ts';

/**
 * The two mutually exclusive views (docs/SPEC.md FR-4.3), a single toggle. What each shows, and
 * how Fog veils the basemap and hides the tracks, is the layers document's views (mapLayers.ts).
 */
export type MapMode = 'normal' | 'fog';

/**
 * Applies `mode`'s view. A no-op before the layers document is on the map. `satellite` picks the
 * view over imagery.
 *
 * `editingRoute` is the Edit route session (§4.7.7): every other track disappears while
 * one is being edited, and the edited one is drawn by its own overlay (routeEdit.ts), so the
 * shared tracks layer and its bands are hidden outright rather than filtered.
 */
export function setMapMode(map: MapLibreMap, mode: MapMode, satellite: boolean, editingRoute = false): void {
  // The mode's view hides the tracks and their pace bands (FR-4.6) outside Normal; an edit steps
  // them aside.
  updateLayers(map, { mode, satellite });
  setHiddenGroups(map, 'editingRoute', editingRoute ? ['tracks', 'route-bands'] : []);
}
