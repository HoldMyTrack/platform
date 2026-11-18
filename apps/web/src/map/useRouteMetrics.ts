import { useEffect, useMemo, useState } from 'react';
import type { Map as MapLibreMap } from 'maplibre-gl';
import { clearRouteBands, setRouteBands } from './routeBands.ts';
import { getTrackRouteMetrics, type TrackRouteMetrics } from '../api.ts';

/**
 * The focused track's pace-colored segments (routeBands.ts, bandsGroup.ts). The metrics are fetched when the
 * focus moves, or [version] changes after a reprocess; until they land the previous track's may
 * be in hand, so drawing checks `trackId` against the focus. Not drawn while the track is hidden
 * (the bands are a layer above it and would keep painting it) or Pending (they'd paint the old
 * shape over the new one). Returns the bands drawn, which a style reload redraws.
 */
export function useRouteMetrics(
  map: MapLibreMap | null,
  focusedId: string | null,
  version: number,
  mapHiddenIds: ReadonlySet<string>,
  pendingIds: readonly string[],
): TrackRouteMetrics | null {
  const [metrics, setMetrics] = useState<TrackRouteMetrics | null>(null);
  useEffect(() => {
    if (!focusedId) {
      setMetrics(null);
      return;
    }
    const controller = new AbortController();
    getTrackRouteMetrics(focusedId, controller.signal)
      .then(setMetrics)
      .catch(() => {
        if (!controller.signal.aborted) setMetrics(null);
      });
    return () => controller.abort();
  }, [focusedId, version]);

  const bands = useMemo(() => {
    if (focusedId === null || metrics?.trackId !== focusedId) return null;
    if (mapHiddenIds.has(focusedId) || pendingIds.includes(focusedId)) return null;
    return metrics;
  }, [metrics, focusedId, mapHiddenIds, pendingIds]);
  useEffect(() => {
    if (!map) return;
    if (bands) setRouteBands(map, bands);
    else clearRouteBands(map);
  }, [map, bands]);
  return bands;
}
