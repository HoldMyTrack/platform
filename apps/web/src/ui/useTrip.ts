import { useCallback, useEffect, useRef, useState } from 'react';
import { getTrip, TripNotFoundError, type Trip } from '../api.ts';

export interface TripState {
  /** null outside a Trip, until it has loaded, and after an error. */
  trip: Trip | null;
  error: string | null;
  /** The Trip doesn't exist, or isn't this account's (FR-13.5). */
  notFound: boolean;
  /** Re-reads it — after anything that changes its tracks or their numbers. */
  reload: () => void;
  /** Replaces it with a copy a write already returned (a rename, a removal) — ignored once
   *  another Trip is open, so a write that lands after a switch can't overwrite the new one. */
  set: (trip: Trip) => void;
}

/** Reader for `GET /v2/trips/{id}` — the open Trip on the Trips tab: its whole-Trip
 *  statistics (FR-13.1) for the footer, whatever the area and Dates. */
export function useTrip(id: string | null): TripState {
  const [trip, setTrip] = useState<Trip | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notFound, setNotFound] = useState(false);
  const [nonce, setNonce] = useState(0);
  const openId = useRef(id);
  openId.current = id;

  useEffect(() => {
    setError(null);
    setNotFound(false);
    if (id === null) {
      setTrip(null);
      return;
    }
    // A different Trip's header must not linger while this one loads; a reload of the same
    // one keeps what's shown until the new copy lands.
    setTrip((current) => (current?.id === id ? current : null));
    const controller = new AbortController();
    getTrip(id, controller.signal)
      .then(setTrip)
      .catch((err: unknown) => {
        if (controller.signal.aborted) return;
        setTrip(null);
        setNotFound(err instanceof TripNotFoundError);
        setError(err instanceof Error ? err.message : String(err));
      });
    return () => controller.abort();
  }, [id, nonce]);

  const reload = useCallback(() => setNonce((n) => n + 1), []);
  const set = useCallback((next: Trip) => {
    if (next.id === openId.current) setTrip(next);
  }, []);
  return { trip, error, notFound, reload, set };
}
