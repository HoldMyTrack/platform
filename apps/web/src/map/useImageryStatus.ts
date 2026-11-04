import { useEffect, useState } from 'react';
import { getMapImagery } from '../api';

/** How often the web asks again: the server decides at most every 30 minutes. */
export const IMAGERY_POLL_MS = 5 * 60_000;

/**
 * The server's word on satellite imagery (`GET /v1/map/imagery`), asked at load and every
 * IMAGERY_POLL_MS: true or false, or null until it answers. A failed read keeps the last answer.
 * Only asked when the build configures imagery at all.
 */
export function useImageryStatus(configured: boolean): boolean | null {
  const [available, setAvailable] = useState<boolean | null>(null);
  useEffect(() => {
    if (!configured) return;
    const abort = new AbortController();
    const ask = () => {
      getMapImagery(abort.signal)
        .then(setAvailable)
        .catch((err: unknown) => {
          if (!abort.signal.aborted) console.warn('imagery status', err);
        });
    };
    ask();
    const timer = window.setInterval(ask, IMAGERY_POLL_MS);
    return () => {
      window.clearInterval(timer);
      abort.abort();
    };
  }, [configured]);
  return available;
}
