import { useEffect, useRef, type Dispatch } from 'react';
import type { Map as MapLibreMap } from 'maplibre-gl';
import { APP_FLIGHT } from './bbox';
import { WORLD_VIEW } from './config';
import { countryView } from './countryView';
import { OPENING_ACTIVITIES, openingView } from './openingView';
import type { MapSessionEvent } from './session';
import { viewArea } from './useAreaList';
import { listArea, type BBox } from '../api';

export interface OpeningViewInputs {
  /** The URL's camera, a Story or an arriving activity decides the camera instead. */
  keepCamera: boolean;
  country: string;
  /** The first activity's day (useHistoryStart.ts) and whether it's known. */
  earliest: string | null;
  historyReady: boolean;
}

/**
 * The web's opening view (docs/SPEC.md FR-4.4) and the list's first area. The newest few tracks
 * are asked for alone (`limit`), since no area is known yet; openingView.ts picks the camera. An
 * account with none gets its Country's view, else the world, never geolocation. An empty
 * account's first activity opens the same way once it lands, so its track is in view, unless the
 * camera is the URL's, a Story's or an arriving activity's.
 */
export function useOpeningView(map: MapLibreMap | null, dispatch: Dispatch<MapSessionEvent>, inputs: OpeningViewInputs): void {
  const { keepCamera, country, earliest, historyReady } = inputs;
  const openedRef = useRef(false);
  const emptyRef = useRef<boolean | null>(null);

  const open = (m: MapLibreMap, signal: AbortSignal) =>
    listArea({ limit: OPENING_ACTIVITIES }, signal)
      .then(({ activities }) => {
        const boxes = activities.flatMap((a): BBox[] => (a.bbox !== null && !a.pending ? [a.bbox] : []));
        const container = m.getContainer();
        const view = openingView(boxes, { width: container.clientWidth, height: container.clientHeight });
        const fallback = countryView(country) ?? WORLD_VIEW;
        const camera = view ?? { center: [fallback.longitude, fallback.latitude] as [number, number], zoom: fallback.zoom };
        m.jumpTo(camera, { [APP_FLIGHT]: true });
      })
      .catch(() => {
        // The camera stays where the map started; the list still follows it.
      })
      .finally(() => {
        if (!signal.aborted) dispatch({ type: 'areaLoaded', area: viewArea(m) });
      });

  useEffect(() => {
    if (!map || openedRef.current) return;
    openedRef.current = true;
    if (keepCamera) {
      dispatch({ type: 'areaLoaded', area: viewArea(map) });
      return;
    }
    const controller = new AbortController();
    void open(map, controller.signal);
    // Once only: a later map instance (a theme swap keeps it) must not move the camera again.
  }, [map]);

  useEffect(() => {
    if (!map || !historyReady || keepCamera) return;
    if (emptyRef.current === null) {
      emptyRef.current = earliest === null;
      return;
    }
    if (emptyRef.current && earliest !== null) {
      emptyRef.current = false;
      const controller = new AbortController();
      void open(map, controller.signal);
    }
  }, [map, historyReady, earliest, keepCamera]);
}
