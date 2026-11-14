/** Where the camera goes when a Story's list lands (FR-13.6), as plain values. */
import type { Activity } from '../api';

/**
 * A Story's first loaded list fits all of it, a trip; a URL view (`#…`) keeps the camera. Returns
 * null to wait for a later list (a Story with nothing drawn yet), else the activities to fit,
 * empty for none. Without a Story the opening view is openingView.ts's.
 */
export function firstListFit(activities: readonly Activity[], storyId: string | null, urlView: boolean): Activity[] | null {
  if (storyId === null || urlView) return [];
  const drawn = activities.filter((a) => a.bbox !== null && !a.pending);
  return drawn.length === 0 ? null : drawn;
}
