/**
 * What a newly fetched list says about reprocesses (a track edit, a Private location change):
 * which started, which finished. Android: `map/PendingDiff.kt`.
 *
 * Trap: a job often finishes before the list reload after Apply returns, so its row is never
 * seen Pending. An activity applied here (`awaiting`) therefore also counts as finished the first
 * time a list fetched after Apply shows it not pending.
 */
export interface PendingChange {
  /** The ids pending now. */
  now: Set<string>;
  /** A row entered Pending. */
  started: boolean;
  /** A row left Pending, or an awaited edit landed. */
  finished: boolean;
  /** Ids that were pending and no longer are. */
  left: Set<string>;
  /** Awaited ids that landed with this list. */
  landed: Set<string>;
  /** Awaited ids still pending. */
  awaiting: Set<string>;
}

export function pendingChange(previous: ReadonlySet<string>, pendingIds: Iterable<string>, awaiting: ReadonlySet<string>): PendingChange {
  const now = new Set(pendingIds);
  const left = new Set([...previous].filter((id) => !now.has(id)));
  const started = [...now].some((id) => !previous.has(id));
  const landed = new Set([...awaiting].filter((id) => !now.has(id)));
  const stillAwaiting = new Set([...awaiting].filter((id) => now.has(id)));
  return { now, started, finished: left.size > 0 || landed.size > 0, left, landed, awaiting: stillAwaiting };
}

/** The ids to ask the Pending check about: the rows the list shows Pending and the edits applied
 *  here, once each. None means there's nothing to watch. */
export function pendingWatched(listed: readonly string[], awaiting: ReadonlySet<string>): string[] {
  return [...new Set([...listed, ...awaiting])];
}

/** The most ids one Pending check request may carry (`GET /v1/activities/pending`). */
export const PENDING_BATCH = 200;

/** [ids] in consecutive batches of at most [size], one Pending check request each; the answers
 *  are read as one. None for no ids. */
export function pendingBatches<T>(ids: readonly T[], size: number = PENDING_BATCH): T[][] {
  const batches: T[][] = [];
  for (let i = 0; i < ids.length; i += size) batches.push(ids.slice(i, i + size));
  return batches;
}

/** Whether the Pending check's answer means the list should be read again: one of the watched
 *  ids is no longer Pending. */
export function pendingMoved(watched: readonly string[], stillPending: readonly string[]): boolean {
  const still = new Set(stillPending);
  return watched.some((id) => !still.has(id));
}
