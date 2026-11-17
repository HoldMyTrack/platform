import { useCallback, useEffect, useRef, useState, type Dispatch } from 'react';
import type { Map as MapLibreMap } from 'maplibre-gl';
import { APP_FLIGHT } from './bbox';
import { settledMove } from './areaLoad';
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

/**
 * The list follows the map (docs/SPEC.md FR-5.11): from zoom 4 every move reloads it once the map
 * settles. The app's own flights (APP_FLIGHT: focusing a row, Focus on map, a Story) leave the list
 * as it is, or clicking a row would shrink the list to that row's track; the opening view and
 * Dates' flight ask for their area themselves. Closing a Story asks about wherever the map is then,
 * and so does closing the Edit window after a move made while it was open (areaLoad.ts's
 * settledMove). Returns the map's zoom as of its last move.
 */
export function useAreaList(map: MapLibreMap | null, dispatch: Dispatch<MapSessionEvent>, storyId: string | null, editOpen: boolean): number {
  const [zoom, setZoom] = useState(() => map?.getZoom() ?? 0);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  // The Edit window as the settle timer finds it, and whether a move is waiting for it to close.
  const editOpenRef = useRef(editOpen);
  const moveWaiting = useRef(false);

  const loadHere = useCallback(() => {
    if (map) dispatch({ type: 'areaLoaded', area: viewArea(map) });
  }, [map, dispatch]);

  useEffect(() => {
    if (!map) return;
    setZoom(map.getZoom());
    const onSettled = () => {
      const move = settledMove(map.getZoom(), editOpenRef.current);
      if (move === 'load') loadHere();
      else if (move === 'later') moveWaiting.current = true;
    };
    const onMoveEnd = (event: object) => {
      setZoom(map.getZoom());
      if ((event as Record<string, unknown>)[APP_FLIGHT] === true) return;
      if (timer.current !== null) clearTimeout(timer.current);
      timer.current = setTimeout(onSettled, SETTLE_MS);
    };
    map.on('moveend', onMoveEnd);
    return () => {
      map.off('moveend', onMoveEnd);
      if (timer.current !== null) clearTimeout(timer.current);
    };
  }, [map, loadHere]);

  useEffect(() => {
    editOpenRef.current = editOpen;
    if (editOpen || !moveWaiting.current || !map) return;
    moveWaiting.current = false;
    if (settledMove(map.getZoom(), false) === 'load') loadHere();
  }, [editOpen, map, loadHere]);

  const storyRef = useRef(storyId);
  useEffect(() => {
    if (storyRef.current !== null && storyId === null) loadHere();
    storyRef.current = storyId;
  }, [storyId, loadHere]);

  return zoom;
}
