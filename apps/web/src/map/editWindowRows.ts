import type { Activity, ActivityDetail } from '../api.ts';

/**
 * The Edit window's activities against the list (useEditWindow.ts). The list follows the map and
 * Back (FR-5.11), so a row leaving it says nothing about the activity: the window keeps the newest
 * row each list showed, and the selection keeps the window's activities while it's open.
 */

/** The newest row of each of [ids] that [listed] holds, over [previous]; [previous] itself when
 *  nothing changed. */
export function latestRows(previous: ReadonlyMap<string, Activity>, listed: readonly Activity[], ids: readonly string[]): ReadonlyMap<string, Activity> {
  const rows = listed.filter((a) => ids.includes(a.id) && previous.get(a.id) !== a);
  if (rows.length === 0) return previous;
  const next = new Map(previous);
  for (const row of rows) next.set(row.id, row);
  return next;
}

/** Each activity read in full, with the newest list row over it. */
export function windowActivities(details: readonly ActivityDetail[], rows: ReadonlyMap<string, Activity>): ActivityDetail[] {
  return details.map((d) => ({ ...d, ...(rows.get(d.id) ?? {}) }));
}

/** The window's activities [listed] lacks: each is read again, to tell one deleted elsewhere. */
export function missingRows(ids: readonly string[], listed: readonly Activity[]): string[] {
  return ids.filter((id) => !listed.some((a) => a.id === id));
}

/** The ids a loaded list keeps in the selection: its rows, and the open window's activities. */
export function selectionKept(listed: readonly string[], windowIds: readonly string[] | null): string[] {
  return windowIds === null ? [...listed] : [...new Set([...listed, ...windowIds])];
}
