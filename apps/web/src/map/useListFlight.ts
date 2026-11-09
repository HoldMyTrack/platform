import { useEffect, useRef } from 'react';
import type { Map as MapLibreMap } from 'maplibre-gl';
import { flyToBBox, unionBBox } from './bbox';
import { firstListFit } from './cameraRules';
import type { Activity } from '../api';

export interface ListFlightInputs {
  activities: readonly Activity[];
  /** The query the list was fetched for; null before the first. */
  loadedKey: string | null;
  storyId: string | null;
  /** The session asked for a flight onto the next list ([onFlown] consumes it). */
  flyRequest: boolean;
  onFlown: () => void;
  mapHiddenIds: ReadonlySet<string>;
  /** The URL carries a camera, which the first list leaves alone. */
  urlView: boolean;
  /** Arriving on one activity (`/?activity=`) flies to it instead of the first list. */
  arrivingOnActivity: boolean;
  fitTo: (activities: Activity[]) => void;
}

/**
 * Camera moves onto a Story's newly loaded list: the first one a page opens on (cameraRules.ts's
 * firstListFit), and one the session asked a flight for (a Story opened from the map). Keyed on
 * the query the list was fetched for, because the list is a new array on every reload: the
 * Pending poll, a finished upload or a Private location change must not move the camera. Without
 * a Story the camera is the opening view's (useOpeningView.ts) and Dates' (useDatesFlight.ts).
 */
export function useListFlight(map: MapLibreMap | null, inputs: ListFlightInputs): void {
  const { activities, loadedKey, storyId, flyRequest, onFlown, mapHiddenIds, urlView, arrivingOnActivity, fitTo } = inputs;
  // Read by the flight without being its dependency: it's keyed on the list, but leaves out tracks that aren't drawn.
  const mapHiddenIdsRef = useRef(mapHiddenIds);
  useEffect(() => {
    mapHiddenIdsRef.current = mapHiddenIds;
  }, [mapHiddenIds]);

  const hasFlownRef = useRef(arrivingOnActivity);
  const flownKeyRef = useRef<string | null>(null);
  useEffect(() => {
    if (!map || loadedKey === null) return;
    if (loadedKey === flownKeyRef.current) return;
    flownKeyRef.current = loadedKey;
    if (!hasFlownRef.current) {
      const fit = firstListFit(activities, storyId, urlView);
      if (fit === null) return;
      hasFlownRef.current = true;
      if (fit.length > 0) fitTo(fit);
      return;
    }
    if (!flyRequest || storyId === null) return;
    onFlown();
    const visible = activities.filter((a) => !mapHiddenIdsRef.current.has(a.id));
    const bounds = unionBBox(visible.flatMap((a) => (a.bbox ? [a.bbox] : [])));
    if (bounds) flyToBBox(map, bounds);
  }, [map, activities, loadedKey, fitTo, storyId, flyRequest]);
}
