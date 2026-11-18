import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { answerTripSend, listTripSends, type TripInbox } from '../api.ts';

/** How often the inbox is re-read while an accepted copy is still arriving — the copy is one
 *  ingest per track, so a few seconds is the right order of magnitude. */
const COPYING_POLL_MS = 3000;

export interface TripInboxState extends TripInbox {
  /** Accepts (true) or declines one waiting copy; rejects with the server's message. */
  answer: (id: string, accept: boolean) => Promise<void>;
}

/**
 * Reader for `GET /v2/trip-sends`, the Trips tab's inbox (`SPEC.md` FR-13.7): the copies of
 * Trips others sent, and the accepted ones still being copied. Read once on mount, for the
 * tab's count of waiting copies, then each time the tab opens (`enabled`), after each answer,
 * and every few seconds while a copy is arriving, whichever tab is open: the first-run panel
 * answers copies on the Tracks tab. `onArrived` runs whenever one has arrived, so the caller
 * can read its Trips and tracks again.
 */
export function useTripInbox(enabled: boolean, onArrived: () => void): TripInboxState {
  const [inbox, setInbox] = useState<TripInbox>({ sends: [], copying: [] });
  const [nonce, setNonce] = useState(0);
  // Counts failed reads, so a failure re-arms the poll below though the inbox didn't change.
  const [failures, setFailures] = useState(0);
  const copyingRef = useRef(0);
  const readRef = useRef(false);
  // The nonce last read: a new one (an answer, a poll) reads whether the tab is open or not.
  const readNonce = useRef(-1);
  const onArrivedRef = useRef(onArrived);
  onArrivedRef.current = onArrived;

  useEffect(() => {
    if (!enabled && readRef.current && nonce === readNonce.current) return;
    readNonce.current = nonce;
    const controller = new AbortController();
    listTripSends(controller.signal)
      .then((result) => {
        readRef.current = true;
        if (result.copying.length < copyingRef.current) onArrivedRef.current();
        copyingRef.current = result.copying.length;
        setInbox(result);
      })
      // The inbox is an extra on the tab: a failed read leaves the last one shown, and a copy
      // still arriving is asked about again.
      .catch(() => {
        if (!controller.signal.aborted) setFailures((n) => n + 1);
      });
    return () => controller.abort();
  }, [enabled, nonce]);

  // Polled only while something is arriving.
  useEffect(() => {
    if (inbox.copying.length === 0) return;
    const timer = window.setTimeout(() => setNonce((n) => n + 1), COPYING_POLL_MS);
    return () => window.clearTimeout(timer);
  }, [inbox, failures]);

  const answer = useCallback(async (id: string, accept: boolean) => {
    // Read again either way: a copy withdrawn meanwhile leaves the inbox.
    try {
      await answerTripSend(id, accept);
    } finally {
      setNonce((n) => n + 1);
    }
  }, []);
  return useMemo(() => ({ ...inbox, answer }), [inbox, answer]);
}
