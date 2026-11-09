import { useCallback, useEffect, useRef, useState, type Dispatch } from 'react';
import type { Map as MapLibreMap } from 'maplibre-gl';
import { APP_FLIGHT } from './bbox';
import { areaLoad } from './areaLoad';
import type { MapSessionEvent } from './session';
import type { BBox } from '../api';

/** How long the map has to settle before the list follows it, so a pan in steps asks once. */
const SETTLE_MS = 300;

/** The visible map as the list's `bbox`, to about a metre so a redraw asks nothing new. */
export function viewArea(map: MapLibreMap): BBox {
  const b = map.getBounds();
  const round = (v: number) => Math.round(v * 1e5) / 1e5;
  return [round(b.getWest()), round(b.getSouth()), round(b.getEast()), round(b.getNorth())];
}

export interface AreaList {
  /** The map's zoom, as of its last move. */
  zoom: number;
  /** The map moved below zoom 10 since the list last followed it: from zoom 4 the button shows. */
  stale: boolean;
  /** The button: the list follows the visible map now. */
  loadHere: () => void;
}

/**
 * The list follows the map (docs/SPEC.md FR-5.19): from zoom 10 every move reloads it once the
 * map settles; below, a move only offers the button, from zoom 4 where tracks are drawn (areaLoad.ts). The app's own flights (APP_FLIGHT: focusing a
 * row, Focus on map, a Story) leave the list as it is, or clicking a row would shrink the list to
 * that row's track; the opening view and Dates' flight ask for their area themselves. Closing a
 * Story asks about wherever the map is then.
 */
export function useAreaList(map: MapLibreMap | null, dispatch: Dispatch<MapSessionEvent>, storyId: string | null): AreaList {
  const [zoom, setZoom] = useState(() => map?.getZoom() ?? 0);
  const [stale, setStale] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  const loadHere = useCallback(() => {
    if (!map) return;
    setStale(false);
    dispatch({ type: 'areaLoaded', area: viewArea(map) });
  }, [map, dispatch]);

  useEffect(() => {
    if (!map) return;
    setZoom(map.getZoom());
    const onMoveEnd = (event: object) => {
      setZoom(map.getZoom());
      if ((event as Record<string, unknown>)[APP_FLIGHT] === true) return;
      if (timer.current !== null) clearTimeout(timer.current);
      if (areaLoad(map.getZoom(), 0, null).load === 'auto') {
        timer.current = setTimeout(loadHere, SETTLE_MS);
      } else {
        setStale(true);
      }
    };
    map.on('moveend', onMoveEnd);
    return () => {
      map.off('moveend', onMoveEnd);
      if (timer.current !== null) clearTimeout(timer.current);
    };
  }, [map, loadHere]);

  const storyRef = useRef(storyId);
  useEffect(() => {
    if (storyRef.current !== null && storyId === null) loadHere();
    storyRef.current = storyId;
  }, [storyId, loadHere]);

  return { zoom, stale, loadHere };
}
