import { useEffect, type Dispatch } from 'react';
import type { Map as MapLibreMap } from 'maplibre-gl';
import { datesQuery } from './trackQuery.ts';
import { flyToBBox, unionBBox } from './bbox.ts';
import { viewArea } from './useAreaList.ts';
import { listArea, type BBox } from '../api.ts';
import type { MapSessionEvent } from './session.ts';
import type { DateFilter } from '../ui/dateFilter.ts';

/** Tags each Dates flight, so its own `moveend` is told from another's. A newer flight's `stop()`
 *  ends the older one early, mid-way: that one's `moveend` is dropped, and only the newest loads
 *  the area. The listener outlives the effect, which re-runs as soon as the flight is consumed. */
const DATES_FLIGHT = 'datesFlight';
let flights = 0;

/**
 * Setting Dates moves the camera once onto what they match, wherever it is (docs/SPEC.md
 * FR-5.12): asked for without an area, since the area holds only what's in view. The list then
 * follows the camera's new view. Nothing matched leaves the camera.
 */
export function useDatesFlight(map: MapLibreMap | null, dispatch: Dispatch<MapSessionEvent>, state: { flyRequest: boolean; tripId: string | null; dates: DateFilter }): void {
  const { flyRequest, tripId, dates } = state;
  useEffect(() => {
    if (!map || !flyRequest || tripId !== null) return;
    const controller = new AbortController();
    let flight = 0;
    const onMoveEnd = (event: object) => {
      if ((event as Record<string, unknown>)[DATES_FLIGHT] !== flight) return;
      map.off('moveend', onMoveEnd);
      if (flight === flights) dispatch({ type: 'areaLoaded', area: viewArea(map) });
    };
    listArea(datesQuery(dates), controller.signal)
      .then(({ tracks }) => {
        const bounds = unionBBox(tracks.flatMap((a): BBox[] => (a.bbox !== null && !a.pending ? [a.bbox] : [])));
        if (!bounds) return;
        flight = ++flights;
        map.on('moveend', onMoveEnd);
        flyToBBox(map, bounds, { [DATES_FLIGHT]: flight });
      })
      .catch(() => {
        // The camera stays; the list still shows Dates over the area in view.
      })
      // Consumed once answered: consuming first would re-run this effect and abort the request.
      .finally(() => {
        if (!controller.signal.aborted) dispatch({ type: 'flyConsumed' });
      });
    return () => controller.abort();
  }, [map, flyRequest, tripId, dates, dispatch]);
}
