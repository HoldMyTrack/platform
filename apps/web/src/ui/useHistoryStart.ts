import { useCallback, useEffect, useState } from 'react';
import { getActivityDayPage } from '../api';

export interface HistoryStart {
  /** The account's first activity's local day, null for an account with none. */
  earliest: string | null;
  /** Its newest activity's local day, null for an account with none. */
  latest: string | null;
  /** True once the first answer has come back, so "no history" can be told from "not asked yet". */
  ready: boolean;
  /** Asks again: an import or a delete can change the first day. */
  reload: () => void;
}

/** The first and newest activities' days: the Dates pickers' bounds (FR-5.12), and the empty
 *  account's first-run panel (FR-5.10). One day of the histogram, the newest, carries both (§4.7). */
export function useHistoryStart(): HistoryStart {
  const [earliest, setEarliest] = useState<string | null>(null);
  const [latest, setLatest] = useState<string | null>(null);
  const [ready, setReady] = useState(false);
  const [nonce, setNonce] = useState(0);
  useEffect(() => {
    const controller = new AbortController();
    getActivityDayPage({ limit: 1 }, controller.signal)
      .then((page) => {
        setEarliest(page.earliest);
        setLatest(page.days[page.days.length - 1]?.date ?? null);
        setReady(true);
      })
      .catch(() => {
        // Left as it was; the next import or delete asks again.
      });
    return () => controller.abort();
  }, [nonce]);
  const reload = useCallback(() => setNonce((n) => n + 1), []);
  return { earliest, latest, ready, reload };
}
