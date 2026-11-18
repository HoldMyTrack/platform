import { useCallback, useEffect, useRef, useState } from 'react';
import { pendingActivities } from '../api.ts';
import { pendingAnswer, pendingBatches, pendingChange, pendingWatched } from './pending.ts';
import { retryDelay } from './retryDelay.ts';

/** How often the Pending check runs while a reprocess is pending: one activity's ingest takes seconds. */
const POLL_MS = 2000;
/** The longest wait between checks while they keep failing. */
const MAX_RETRY_MS = 60_000;

export interface PendingPollHandlers {
  reload: () => void;
  /** A row entered Pending: it was drawn from tiles fetched before, and the server now leaves it out. */
  onStarted: () => void;
  /** A row left Pending, or an awaited edit landed: it has new points. */
  onFinished: () => void;
}

/**
 * Rows with a reprocess running (a track edit, a Private location change): while any is held
 * Pending or an edit applied here ([awaitEdit]) is awaited, the small Pending check runs every few
 * seconds (`pendingBatches`), and a failed check is tried again, less often after each failure in
 * a row (retryDelay.ts). A hidden tab asks nothing until it's shown. Each fetched list (a new
 * `pendingIds` array, with `listedIds` its rows) says what started and finished, and the check
 * answers for what the list doesn't show (pending.ts).
 *
 * Trap: a reload aborts the one in flight, so the check asks for none while the list loads; on a
 * connection slower than the poll every list would be aborted before it landed.
 *
 * Trap: [awaitEdit] restarts the poll and aborts the check in flight, whose answer was asked
 * before Apply and would count the new edit as landed. The restart also watches the edit when the
 * reload after Apply fails.
 */
export function usePendingPoll(listedIds: readonly string[], pendingIds: string[], loading: boolean, handlers: PendingPollHandlers): (id: string) => void {
  const handlersRef = useRef(handlers);
  handlersRef.current = handlers;
  const loadingRef = useRef(loading);
  loadingRef.current = loading;

  const heldRef = useRef<Set<string>>(new Set());
  const awaitingRef = useRef<Set<string>>(new Set());
  const lastRef = useRef<string[] | null>(null);
  const controllerRef = useRef<AbortController | null>(null);
  const [restarts, setRestarts] = useState(0);

  useEffect(() => {
    const listed = new Set(listedIds);
    // Only a newly fetched list says anything new.
    if (pendingIds !== lastRef.current) {
      lastRef.current = pendingIds;
      const change = pendingChange(heldRef.current, pendingIds, awaitingRef.current, listed);
      heldRef.current = change.pending;
      awaitingRef.current = change.awaiting;
      if (change.started) handlersRef.current.onStarted();
      if (change.finished) handlersRef.current.onFinished();
    }
    if (pendingWatched(heldRef.current, awaitingRef.current).length === 0) return;
    const controller = new AbortController();
    controllerRef.current = controller;
    let timer = 0;
    let failures = 0;
    // A hidden tab waits to be shown, then checks at once, its failures forgotten: no timer wakes
    // it meanwhile, and a long backoff doesn't hold a reprocess that finished while it was away.
    const onShown = () => {
      if (document.hidden) return;
      document.removeEventListener('visibilitychange', onShown);
      failures = 0;
      run();
    };
    const check = () => {
      timer = window.setTimeout(run, retryDelay(failures, POLL_MS, MAX_RETRY_MS));
    };
    function run() {
      if (document.hidden) {
        document.addEventListener('visibilitychange', onShown);
        return;
      }
      const watched = pendingWatched(heldRef.current, awaitingRef.current);
      const checks = pendingBatches(watched).map((ids) => pendingActivities(ids, controller.signal));
      Promise.all(checks).then(
        (answers) => {
          if (controller.signal.aborted) return;
          failures = 0;
          const { moved, finished } = pendingAnswer(watched, answers.flat(), listed);
          if (finished.size > 0) {
            for (const id of finished) {
              heldRef.current.delete(id);
              awaitingRef.current.delete(id);
            }
            handlersRef.current.onFinished();
          }
          // Polling goes on after asking for a reload: a successful one brings a new list and
          // restarts this, a failed one leaves the same list, and the next check asks again.
          if (moved && !loadingRef.current) handlersRef.current.reload();
          if (pendingWatched(heldRef.current, awaitingRef.current).length > 0) check();
        },
        () => {
          if (controller.signal.aborted) return;
          failures += 1;
          check();
        },
      );
    }
    check();
    return () => {
      window.clearTimeout(timer);
      document.removeEventListener('visibilitychange', onShown);
      controller.abort();
    };
  }, [listedIds, pendingIds, restarts]);

  return useCallback((id: string) => {
    controllerRef.current?.abort();
    awaitingRef.current.add(id);
    setRestarts((n) => n + 1);
  }, []);
}
