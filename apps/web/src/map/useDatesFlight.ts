import { useEffect, type Dispatch } from 'react';
import type { Map as MapLibreMap } from 'maplibre-gl';
import { datesQuery } from './activityQuery';
import { flyToBBox, unionBBox } from './bbox';
import { viewArea } from './useAreaList';
import { listArea, type BBox } from '../api';
import type { MapSessionEvent } from './session';
import type { DateFilter } from '../ui/dateFilter';

/**
 * Setting Dates moves the camera once onto what they match, wherever it is (docs/SPEC.md
 * FR-5.12): asked for without an area, since the area holds only what's in view. The list then
 * follows the camera's new view. Nothing matched leaves the camera.
 */
export function useDatesFlight(map: MapLibreMap | null, dispatch: Dispatch<MapSessionEvent>, state: { flyRequest: boolean; storyId: string | null; dates: DateFilter }): void {
  const { flyRequest, storyId, dates } = state;
  useEffect(() => {
    if (!map || !flyRequest || storyId !== null) return;
    const controller = new AbortController();
    listArea(datesQuery(dates), controller.signal)
      .then(({ activities }) => {
        const bounds = unionBBox(activities.flatMap((a): BBox[] => (a.bbox !== null && !a.pending ? [a.bbox] : [])));
        if (!bounds) return;
        map.once('moveend', () => dispatch({ type: 'areaLoaded', area: viewArea(map) }));
        flyToBBox(map, bounds);
      })
      .catch(() => {
        // The camera stays; the list still shows Dates over the area in view.
      })
      // Consumed once answered: consuming first would re-run this effect and abort the request.
      .finally(() => {
        if (!controller.signal.aborted) dispatch({ type: 'flyConsumed' });
      });
    return () => controller.abort();
  }, [map, flyRequest, storyId, dates, dispatch]);
}
