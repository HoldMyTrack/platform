/** Where the camera goes when a Trip's list lands (FR-13.6), as plain values. */
import type { Track } from '../api.ts';

/**
 * A Trip's first loaded list fits all of it, a trip; a URL view (`#…`) keeps the camera. Returns
 * null to wait for a later list (a Trip with nothing drawn yet), else the tracks to fit,
 * empty for none. Without a Trip the opening view is openingView.ts's.
 */
export function firstListFit(tracks: readonly Track[], tripId: string | null, urlView: boolean): Track[] | null {
  if (tripId === null || urlView) return [];
  const drawn = tracks.filter((a) => a.bbox !== null && !a.pending);
  return drawn.length === 0 ? null : drawn;
}
