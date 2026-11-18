import { useCallback, useEffect } from 'react';
import type { Map as MapLibreMap } from 'maplibre-gl';
import { refreshTrackLayer } from './tracks.ts';
import type { TrackQuery } from '../api.ts';

interface DataRefreshInputs {
  tracksQuery: TrackQuery;
  reloadTracks: () => void;
  reloadDays: () => void;
  reloadTrip: () => void;
  /** Waits for the account's coverage jobs to drain, then refetches Fog (useCoverageRefresh.ts). */
  watchCoverage: (then?: () => void) => void;
  /** The bands refetch against new points. */
  bumpMetrics: () => void;
}

interface DataRefresh {
  /** The tracks layer at the current query, fetched again. */
  refreshTracks: () => void;
  /** A finished import or a delete: tracks, list, days, the open Trip and coverage all refresh. */
  afterImport: () => void;
  /**
   * A saved or deleted Private location reprocesses every track it could clip. The reload shows
   * them Pending and the Pending poll refreshes the map, but a batch that finishes before the
   * reload returns is never seen Pending, so the coverage watch refreshes everything once the
   * server drains.
   */
  afterPrivateLocations: () => void;
  /**
   * A row entered Pending (usePendingPoll.ts): the tracks refetch and the coverage watch starts,
   * since the server clears Pending just before its last render.
   */
  pendingStarted: () => void;
  /** A row left Pending with new points: tracks, days, the open Trip, the bands and coverage
   *  refresh; the camera stays (FR-5.8). */
  pendingFinished: () => void;
}

/** What the map reads again when tracks change under it. The header's Upload menu
 *  (static/upload.js) says when an upload or import has landed (`hmt:imports-changed`). */
export function useDataRefresh(map: MapLibreMap | null, inputs: DataRefreshInputs): DataRefresh {
  const { tracksQuery, reloadTracks, reloadDays, reloadTrip, watchCoverage, bumpMetrics } = inputs;
  const refreshTracks = useCallback(() => {
    if (map) refreshTrackLayer(map, tracksQuery);
  }, [map, tracksQuery]);

  const afterImport = useCallback(() => {
    refreshTracks();
    reloadTracks();
    reloadDays();
    reloadTrip();
    watchCoverage();
  }, [refreshTracks, reloadTracks, reloadDays, reloadTrip, watchCoverage]);

  useEffect(() => {
    window.addEventListener('hmt:imports-changed', afterImport);
    return () => window.removeEventListener('hmt:imports-changed', afterImport);
  }, [afterImport]);

  const afterPrivateLocations = useCallback(() => {
    reloadTracks();
    watchCoverage(() => {
      refreshTracks();
      reloadTracks();
      reloadDays();
      reloadTrip();
      bumpMetrics();
    });
  }, [refreshTracks, reloadTracks, reloadDays, reloadTrip, watchCoverage, bumpMetrics]);

  const pendingStarted = useCallback(() => {
    refreshTracks();
    watchCoverage();
  }, [refreshTracks, watchCoverage]);

  const pendingFinished = useCallback(() => {
    refreshTracks();
    // Includes the Country/Region tiers: an edit can un-visit a region.
    watchCoverage();
    reloadDays();
    reloadTrip();
    bumpMetrics();
  }, [refreshTracks, watchCoverage, reloadDays, reloadTrip, bumpMetrics]);

  return { refreshTracks, afterImport, afterPrivateLocations, pendingStarted, pendingFinished };
}
