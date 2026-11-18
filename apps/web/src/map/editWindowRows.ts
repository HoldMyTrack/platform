import type { Track, TrackDetail } from '../api.ts';

/**
 * The Edit window's tracks against the list (useEditWindow.ts). The list follows the map and
 * Back (FR-5.11), so a row leaving it says nothing about the track: the window keeps the newest
 * row each list showed, and the selection keeps the window's tracks while it's open.
 */

/** The newest row of each of [ids] that [listed] holds, over [previous]; [previous] itself when
 *  nothing changed. */
export function latestRows(previous: ReadonlyMap<string, Track>, listed: readonly Track[], ids: readonly string[]): ReadonlyMap<string, Track> {
  const rows = listed.filter((a) => ids.includes(a.id) && previous.get(a.id) !== a);
  if (rows.length === 0) return previous;
  const next = new Map(previous);
  for (const row of rows) next.set(row.id, row);
  return next;
}

/** Each track read in full, with the newest list row over it. */
export function windowTracks(details: readonly TrackDetail[], rows: ReadonlyMap<string, Track>): TrackDetail[] {
  return details.map((d) => ({ ...d, ...(rows.get(d.id) ?? {}) }));
}

/** The window's tracks [listed] lacks: each is read again, to tell one deleted elsewhere. */
export function missingRows(ids: readonly string[], listed: readonly Track[]): string[] {
  return ids.filter((id) => !listed.some((a) => a.id === id));
}

/** The ids a loaded list keeps in the selection: its rows, and the open window's tracks. */
export function selectionKept(listed: readonly string[], windowIds: readonly string[] | null): string[] {
  return windowIds === null ? [...listed] : [...new Set([...listed, ...windowIds])];
}
