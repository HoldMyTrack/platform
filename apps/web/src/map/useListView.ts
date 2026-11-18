import { useEffect, useMemo, type Dispatch } from 'react';
import type { MapSessionEvent, Selection } from './session.ts';
import { mapHiddenIds as hiddenOnMap } from './selection.ts';
import type { Track } from '../api.ts';
import { distanceBounds, passesFilters, typeFacets, type DistanceRange, type TypeFacet } from '../ui/trackFacets.ts';

interface ListView {
  /** Rows with a reprocess pending (a route edit or a Private location change). A Pending track isn't drawn (FR-5.8). */
  pendingIds: string[];
  distanceBounds: DistanceRange | null;
  facets: TypeFacet[];
  /** The rows the panel lists: the loaded tracks narrowed by the TYPE/DISTANCE filters. */
  listed: Track[];
  /** Tracks not drawn: filtered out, hidden or Pending. The tile already omits a Pending one; this
   *  hides it before the refetch lands. */
  mapHiddenIds: Set<string>;
}

/** What the loaded tracks and the selection's filters make of the list and the map. */
export function useListView(tracks: Track[], selection: Selection, dispatch: Dispatch<MapSessionEvent>): ListView {
  const { excludedTypes, distanceFilter, hidden } = selection;
  const pendingIds = useMemo(() => tracks.filter((a) => a.pending).map((a) => a.id), [tracks]);
  const bounds = useMemo(() => distanceBounds(tracks), [tracks]);
  // The distance slider shows only while the tracks span a range. A band left set after that
  // would keep filtering with nothing on screen to clear it.
  const sliderShown = bounds !== null && bounds.min < bounds.max;
  useEffect(() => {
    if (!sliderShown) dispatch({ type: 'distanceSet', filter: null, tracks });
  }, [sliderShown, dispatch, tracks]);
  const facets = useMemo(() => typeFacets(tracks, distanceFilter), [tracks, distanceFilter]);
  const listed = useMemo(() => tracks.filter((a) => passesFilters(a, excludedTypes, distanceFilter)), [tracks, excludedTypes, distanceFilter]);
  const mapHiddenIds = useMemo(
    () => hiddenOnMap(tracks, excludedTypes, distanceFilter, hidden, pendingIds),
    [tracks, excludedTypes, distanceFilter, hidden, pendingIds],
  );
  return { pendingIds, distanceBounds: bounds, facets, listed, mapHiddenIds };
}
