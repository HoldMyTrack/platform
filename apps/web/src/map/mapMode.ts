import type { Map as MapLibreMap } from 'maplibre-gl';
import { setHiddenGroups, updateLayers } from './applyLayers';

/**
 * The two mutually exclusive views (docs/SPEC.md FR-4.4), a single toggle. What each shows, and
 * how Fog veils the basemap and hides the tracks, is the layers document's views (mapLayers.ts).
 */
export type MapMode = 'normal' | 'fog';

/**
 * Applies `mode`'s view. A no-op before the layers document is on the map. `satellite` picks the
 * view over imagery.
 *
 * `editingTrack` is the Edit track session (§4.7.7): every other activity disappears while
 * one is being edited, and the edited one is drawn by its own overlay (trackEdit.ts), so the
 * shared tracks layer and its bands are hidden outright rather than filtered.
 */
export function setMapMode(map: MapLibreMap, mode: MapMode, satellite: boolean, editingTrack = false): void {
  // The mode's view hides the tracks and their pace bands (FR-4.8) outside Normal; an edit steps
  // them aside.
  updateLayers(map, { mode, satellite });
  setHiddenGroups(map, 'editingTrack', editingTrack ? ['tracks', 'track-bands'] : []);
}
