import { useCallback, useEffect, useState } from 'react';
import { listActivities, listArea, type Activity } from '../api';
import type { ListRequest } from '../map/activityQuery';

export interface ActivityList {
  activities: Activity[];
  /** How many the area holds, past the rows when they were cut at the limit; null without an area. */
  total: number | null;
  loading: boolean;
  error: string | null;
  /** Re-reads the list; the upload widget calls this once a job actually finishes. */
  reload: () => void;
  /** The query `activities` was fetched for (serialised), null before the first fetch lands —
   *  lets a caller tell a new query's first list from a reload of the same one. */
  loadedKey: string | null;
}

/**
 * Reader for the list: a Story's `GET /v1/activities?story=`, else the area's
 * `GET /v1/activities/area` (§4.7). One request, the whole set — the panel renders every row, the
 * map draws the same set, and the type/distance facets are computed over it. A null request (no
 * area yet) asks for nothing and stays loading.
 *
 * The filter is compared by its serialised form, not by identity, so a caller passing a
 * fresh object literal every render doesn't restart the fetch on every render.
 */
export function useActivityList(query: ListRequest | null): ActivityList {
  const queryKey = query === null ? null : JSON.stringify(query);
  const [activities, setActivities] = useState<Activity[]>([]);
  const [total, setTotal] = useState<number | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [nonce, setNonce] = useState(0);
  const [loadedKey, setLoadedKey] = useState<string | null>(null);

  useEffect(() => {
    if (queryKey === null) return;
    setLoading(true);
    const controller = new AbortController();
    const request = JSON.parse(queryKey) as ListRequest;
    ('story' in request ? listActivities(request.story, controller.signal) : listArea(request.area, controller.signal))
      .then((page) => {
        setActivities(page.activities);
        setTotal(page.total);
        setLoadedKey(queryKey);
        setError(null);
      })
      .catch((err: unknown) => {
        if (controller.signal.aborted) return;
        setError(err instanceof Error ? err.message : String(err));
      })
      .finally(() => {
        if (controller.signal.aborted) return;
        setLoading(false);
      });
    return () => controller.abort();
  }, [queryKey, nonce]);

  const reload = useCallback(() => setNonce((n) => n + 1), []);
  return { activities, total, loading, error, reload, loadedKey };
}
