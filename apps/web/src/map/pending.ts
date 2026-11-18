/**
 * What a newly fetched list says about reprocesses (a route edit, a Private location change):
 * which started, which finished. Android: `map/PendingDiff.kt`; iOS: `Rules/Pending.swift`.
 *
 * Trap: a job often finishes before the list reload after Apply returns, so its row is never
 * seen Pending. A track applied here (`awaiting`) therefore also counts as finished the first
 * time a list fetched after Apply shows it not pending.
 *
 * Trap: the list is an area's (FR-5.11), and a move of the map or Back takes rows out of it. A
 * missing row says nothing about its reprocess, so the list speaks only for the rows it holds
 * (`listed`); the Pending check answers for the rest (`pendingAnswer`).
 */
interface PendingChange {
  /** The ids held Pending: the list's, and those it doesn't show that were. */
  pending: Set<string>;
  /** A row entered Pending. */
  started: boolean;
  /** A row left Pending, or an awaited edit landed. */
  finished: boolean;
  /** Ids that were pending and no longer are. */
  left: Set<string>;
  /** Awaited ids that landed with this list. */
  landed: Set<string>;
  /** Awaited ids not seen landing. */
  awaiting: Set<string>;
}

export function pendingChange(previous: ReadonlySet<string>, pendingIds: Iterable<string>, awaiting: ReadonlySet<string>, listed: ReadonlySet<string>): PendingChange {
  const now = new Set(pendingIds);
  const done = (id: string) => listed.has(id) && !now.has(id);
  const left = new Set([...previous].filter(done));
  const landed = new Set([...awaiting].filter(done));
  const started = [...now].some((id) => !previous.has(id));
  const pending = new Set([...now, ...[...previous].filter((id) => !listed.has(id))]);
  const stillAwaiting = new Set([...awaiting].filter((id) => !landed.has(id)));
  return { pending, started, finished: left.size > 0 || landed.size > 0, left, landed, awaiting: stillAwaiting };
}

/** The ids to ask the Pending check about: the rows held Pending and the edits applied here, once
 *  each. None means there's nothing to watch. */
export function pendingWatched(pending: Iterable<string>, awaiting: Iterable<string>): string[] {
  return [...new Set([...pending, ...awaiting])];
}

/** The most ids one Pending check request may carry (`GET /v1/activities/pending`). */
const PENDING_BATCH = 200;

/** [ids] in consecutive batches of at most [size], one Pending check request each; the answers
 *  are read as one. None for no ids. */
export function pendingBatches<T>(ids: readonly T[], size: number = PENDING_BATCH): T[][] {
  const batches: T[][] = [];
  for (let i = 0; i < ids.length; i += size) batches.push(ids.slice(i, i + size));
  return batches;
}

/** What the Pending check's answer says about the [watched] ids no longer Pending: one the list
 *  holds means reading it again (`moved`); one it doesn't has finished, since no list will say so. */
export function pendingAnswer(watched: readonly string[], stillPending: readonly string[], listed: ReadonlySet<string>): { moved: boolean; finished: Set<string> } {
  const still = new Set(stillPending);
  const done = watched.filter((id) => !still.has(id));
  return { moved: done.some((id) => listed.has(id)), finished: new Set(done.filter((id) => !listed.has(id))) };
}