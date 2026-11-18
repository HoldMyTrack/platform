import { useCallback, useEffect, useState } from 'react';
import { listTrips, type Trip } from '../api.ts';

export interface TripsState {
  /** Newest first (`created_at`), as `GET /v2/trips` returns them. */
  trips: Trip[];
  /** A list fetched since the tab last opened is in hand. */
  ready: boolean;
  error: string | null;
  /** Replaces one Trip with a copy a write already returned (a rename). */
  replace: (trip: Trip) => void;
  /** Drops a deleted Trip from the list in hand, rather than refetching: a refetch leaves the
   *  old list, deleted Trip included, ready until it lands. */
  remove: (id: string) => void;
  /** Reads the list again, keeping the one in hand until it lands — a copy someone sent has
   *  arrived (useTripInbox). */
  reload: () => void;
}

/** Reader for `GET /v2/trips`, the Trips tab's list (`SPEC.md` FR-13.6). Fetched each time
 *  the tab opens (`enabled`), so a Trip made or changed elsewhere — Create trip included — is
 *  there without a reload. */
export function useTrips(enabled: boolean): TripsState {
  const [trips, setTrips] = useState<Trip[]>([]);
  const [ready, setReady] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // Bumped by reload: a read that keeps `ready`, unlike the tab opening.
  const [reloads, setReloads] = useState(0);

  useEffect(() => setReady(false), [enabled]);

  useEffect(() => {
    if (!enabled) return;
    const controller = new AbortController();
    listTrips(controller.signal)
      .then((result) => {
        setTrips(result);
        setError(null);
        setReady(true);
      })
      .catch((err: unknown) => {
        if (controller.signal.aborted) return;
        setError(err instanceof Error ? err.message : String(err));
      });
    return () => controller.abort();
  }, [enabled, reloads]);

  const replace = useCallback(
    (trip: Trip) => setTrips((current) => current.map((s) => (s.id === trip.id ? trip : s))),
    [],
  );
  const remove = useCallback((id: string) => setTrips((current) => current.filter((s) => s.id !== id)), []);
  const reload = useCallback(() => setReloads((n) => n + 1), []);
  return { trips, ready, error, replace, remove, reload };
}