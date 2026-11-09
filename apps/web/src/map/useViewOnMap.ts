import { useCallback, useEffect, useRef, type Dispatch } from 'react';
import type { Map as MapLibreMap } from 'maplibre-gl';
import type { MapMode } from './mapMode';
import type { MapSessionEvent } from './session';
import type { Activity } from '../api';

/**
 * "View on map" (`/?activity=&day=`, the /sync page's link), once, on arrival. Normal mode first,
 * since only it focuses. An activity already listed is focused at once; else Dates becomes its
 * day, the camera moves onto that day's tracks (useDatesFlight.ts), and the focus waits until the
 * list holds it. The day is the activity's local day, as the server reads a bare from/to
 * (IMPLEMENTATION.md §4.30); a UTC day would miss an evening activity west of Greenwich.
 */
export function useViewOnMap(
  map: MapLibreMap | null,
  target: { id: string; day: string } | null,
  state: { mode: MapMode; activities: readonly Activity[] },
  dispatch: Dispatch<MapSessionEvent>,
  focus: (id: string) => void,
): void {
  const { mode, activities } = state;
  const pendingFocusRef = useRef<string | null>(null);
  const view = useCallback(
    (activityId: string, day: string) => {
      if (mode !== 'normal') dispatch({ type: 'modeChanged', mode: 'normal' });
      if (activities.some((a) => a.id === activityId)) {
        focus(activityId);
        return;
      }
      pendingFocusRef.current = activityId;
      dispatch({ type: 'dayViewed', day });
    },
    [mode, dispatch, activities, focus],
  );
  const arrivedRef = useRef(false);
  useEffect(() => {
    if (target === null || arrivedRef.current || !map) return;
    arrivedRef.current = true;
    view(target.id, target.day);
  }, [target, view, map]);
  useEffect(() => {
    const pending = pendingFocusRef.current;
    if (pending === null || !map) return;
    if (activities.some((a) => a.id === pending)) {
      pendingFocusRef.current = null;
      focus(pending);
    }
  }, [map, activities, focus]);
}
