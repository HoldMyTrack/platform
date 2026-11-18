import { useCallback, type Dispatch } from 'react';
import type { MapSessionEvent } from './session.ts';
import { invertedChecks } from './selection.ts';
import type { Track } from '../api.ts';
import type { DistanceRange } from '../ui/trackFacets.ts';

interface SelectionActions {
  toggleChecked: (id: string) => void;
  /** The toolbar's Show/Hide over its target. */
  toggleGroupVisibility: () => void;
  /** A toggle: the type stays in the dropdown either way, so it can be turned back on without Reset filters. */
  toggleType: (activityType: string) => void;
  setDistanceFilter: (filter: DistanceRange | null) => void;
  /** Focuses one track and flies to it, unless it's hidden (an empty fit is a no-op). With
   *  Focus on map, the only fly to a track. */
  focus: (id: string) => void;
  /** A click on empty list space, the counterpart of clicking away from every track. The checked group stays. */
  clearFocus: () => void;
  /** The master checkbox while fully checked: empties the group; the focus stays. */
  clearChecked: () => void;
  /** The master checkbox while unchecked or partial: every row listed, never one the filters hide. No fly. */
  checkAll: () => void;
  /** Inverts the check over the listed rows; a checked row the filters hide is dropped. No fly. */
  invertChecked: () => void;
  /** Focus on map: flies to the toolbar's target, hidden tracks excluded. The one way to look at a checked group. */
  showTarget: () => void;
}

export function useSelectionActions(
  dispatch: Dispatch<MapSessionEvent>,
  tracks: readonly Track[],
  listed: readonly Track[],
  checked: ReadonlySet<string>,
  target: ReadonlySet<string>,
  mapHiddenIds: ReadonlySet<string>,
  fitTo: (tracks: Track[]) => void,
): SelectionActions {
  const focus = useCallback(
    (id: string) => {
      dispatch({ type: 'focused', id });
      fitTo(tracks.filter((a) => a.id === id && !mapHiddenIds.has(a.id)));
    },
    [dispatch, tracks, mapHiddenIds, fitTo],
  );
  const toggleChecked = useCallback((id: string) => dispatch({ type: 'checkToggled', id }), [dispatch]);
  const toggleGroupVisibility = useCallback(() => dispatch({ type: 'visibilityToggled' }), [dispatch]);
  const toggleType = useCallback((activityType: string) => dispatch({ type: 'typeToggled', activityType, tracks }), [dispatch, tracks]);
  const setDistanceFilter = useCallback((filter: DistanceRange | null) => dispatch({ type: 'distanceSet', filter, tracks }), [dispatch, tracks]);
  const clearFocus = useCallback(() => dispatch({ type: 'focused', id: null }), [dispatch]);
  const clearChecked = useCallback(() => dispatch({ type: 'checkedSet', ids: [] }), [dispatch]);
  const checkAll = useCallback(() => dispatch({ type: 'checkedSet', ids: listed.map((a) => a.id) }), [dispatch, listed]);
  const invertChecked = useCallback(() => dispatch({ type: 'checkedSet', ids: invertedChecks(listed, checked) }), [dispatch, listed, checked]);
  const showTarget = useCallback(
    () => fitTo(tracks.filter((a) => target.has(a.id) && !mapHiddenIds.has(a.id))),
    [tracks, target, mapHiddenIds, fitTo],
  );
  return { toggleChecked, toggleGroupVisibility, toggleType, setDistanceFilter, focus, clearFocus, clearChecked, checkAll, invertChecked, showTarget };
}
