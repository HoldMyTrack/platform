import { useCallback, useEffect, useState } from 'react';
import { getActivityDayPage } from '../api';

export interface HistoryStart {
  /** The account's first activity's local day, null for an account with none. */
  earliest: string | null;
  /** True once the first answer has come back, so "no history" can be told from "not asked yet". */
  ready: boolean;
  /** Asks again: an import or a delete can change the first day. */
  reload: () => void;
}

/** The first activity's day: the Dates pickers' bound (FR-5.20) and the empty account's first-run
 *  panel (FR-5.18). One day of the histogram carries it (§4.7). */
export function useHistoryStart(): HistoryStart {
  const [earliest, setEarliest] = useState<string | null>(null);
  const [ready, setReady] = useState(false);
  const [nonce, setNonce] = useState(0);
  useEffect(() => {
    const controller = new AbortController();
    getActivityDayPage({ limit: 1 }, controller.signal)
      .then((page) => {
        setEarliest(page.earliest);
        setReady(true);
      })
      .catch(() => {
        // Left as it was; the next import or delete asks again.
      });
    return () => controller.abort();
  }, [nonce]);
  const reload = useCallback(() => setNonce((n) => n + 1), []);
  return { earliest, ready, reload };
}
