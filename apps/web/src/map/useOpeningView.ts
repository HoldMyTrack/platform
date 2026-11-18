import { useEffect, useRef, type Dispatch } from 'react';
import type { Map as MapLibreMap } from 'maplibre-gl';
import { APP_FLIGHT } from './bbox.ts';
import { WORLD_VIEW } from './config.ts';
import { countryView } from './countryView.ts';
import { OPENING_ACTIVITIES, openingView } from './openingView.ts';
import type { MapSessionEvent } from './session.ts';
import { viewArea } from './useAreaList.ts';
import { listArea, type BBox } from '../api.ts';

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

  // The user moving the map first wins: the view is dropped, and their own move loads the list.
  const open = (m: MapLibreMap) => {
    const controller = new AbortController();
    const { signal } = controller;
    const onMoveStart = (event: { originalEvent?: unknown }) => {
      if (event.originalEvent) controller.abort();
    };
    m.on('movestart', onMoveStart);
    return listArea({ limit: OPENING_ACTIVITIES }, signal)
      .then(({ activities }) => {
        if (signal.aborted) return;
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
        m.off('movestart', onMoveStart);
        if (!signal.aborted) dispatch({ type: 'areaLoaded', area: viewArea(m) });
      });
  };

  useEffect(() => {
    if (!map || openedRef.current) return;
    openedRef.current = true;
    if (keepCamera) {
      dispatch({ type: 'areaLoaded', area: viewArea(map) });
      return;
    }
    void open(map);
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
      void open(map);
    }
  }, [map, historyReady, earliest, keepCamera]);
}
