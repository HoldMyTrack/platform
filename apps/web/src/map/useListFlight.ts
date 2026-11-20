import { useEffect, useRef } from 'react';
import type { Map as MapLibreMap } from 'maplibre-gl';
import { flyToBBox, unionBBox } from './bbox.ts';
import { firstListFit, fitBoxes } from './cameraRules.ts';
import type { Track } from '../api.ts';

interface ListFlightInputs {
  tracks: readonly Track[];
  /** The query the list was fetched for; null before the first. */
  loadedKey: string | null;
  tripId: string | null;
  /** The session asked for a flight onto the next list ([onFlown] consumes it). */
  flyRequest: boolean;
  onFlown: () => void;
  mapHiddenIds: ReadonlySet<string>;
  /** The URL carries a camera, which the first list leaves alone. */
  urlView: boolean;
  /** Arriving on one track (`/?track=`) flies to it instead of the first list. */
  arrivingOnTrack: boolean;
  fitTo: (tracks: Track[]) => void;
}

/**
 * Camera moves onto a Trip's newly loaded list: the first one a page opens on (cameraRules.ts's
 * firstListFit), and one the session asked a flight for (a Trip opened from the map). Keyed on
 * the query the list was fetched for, because the list is a new array on every reload: the
 * Pending poll, a finished upload or a Private location change must not move the camera. Without
 * a Trip the camera is the opening view's (useOpeningView.ts) and Dates' (useDatesFlight.ts).
 */
export function useListFlight(map: MapLibreMap | null, inputs: ListFlightInputs): void {
  const { tracks, loadedKey, tripId, flyRequest, onFlown, mapHiddenIds, urlView, arrivingOnTrack, fitTo } = inputs;
  // Read by the flight without being its dependency: it's keyed on the list, but leaves out tracks that aren't drawn.
  const mapHiddenIdsRef = useRef(mapHiddenIds);
  useEffect(() => {
    mapHiddenIdsRef.current = mapHiddenIds;
  }, [mapHiddenIds]);

  const hasFlownRef = useRef(arrivingOnTrack);
  const flownKeyRef = useRef<string | null>(null);
  useEffect(() => {
    if (!map || loadedKey === null) return;
    if (loadedKey === flownKeyRef.current) return;
    if (!hasFlownRef.current) {
      const fit = firstListFit(tracks, tripId, urlView);
      // Waiting for a later list, which may be a reload of this same query (a Trip opened by URL
      // while its tracks are all Pending), so the key isn't taken yet.
      if (fit === null) return;
      flownKeyRef.current = loadedKey;
      hasFlownRef.current = true;
      if (fit.length > 0) fitTo(fit);
      return;
    }
    flownKeyRef.current = loadedKey;
    if (!flyRequest || tripId === null) return;
    onFlown();
    const visible = tracks.filter((a) => !mapHiddenIdsRef.current.has(a.id));
    const bounds = unionBBox(fitBoxes(visible));
    if (bounds) flyToBBox(map, bounds);
  }, [map, tracks, loadedKey, fitTo, tripId, flyRequest]);
}
