import type { Map as MapLibreMap } from 'maplibre-gl';
import { ROADS_METADATA } from './style';

/** Shows or hides the layers the style's ROADS_METADATA lists (roads.ts's roadLayerIds). Diffs
 *  before setting, like satellite.ts, since reattachOverlays calls it on every 'styledata'. */
export function setRoadsVisible(map: MapLibreMap, shown: boolean): void {
  const roads = (map.getStyle().metadata as Record<string, unknown> | undefined)?.[ROADS_METADATA];
  const next = shown ? 'visible' : 'none';
  for (const id of Array.isArray(roads) ? (roads as string[]) : []) {
    if (map.getLayer(id) && map.getLayoutProperty(id, 'visibility') !== next) map.setLayoutProperty(id, 'visibility', next);
  }
}