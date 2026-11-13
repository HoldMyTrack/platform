import { NOTHING_SEEN, readTourSeen, type TourSeen } from './tourRules.ts';

/** What the tour has shown in this browser (docs/SPEC.md FR-4.18). A per-browser record like the Layers picks (map/overlays.ts): the demo is one account shared by every visitor. */
const STORAGE_KEY = 'hmt.tour';

export function loadTourSeen(): TourSeen {
  try {
    return readTourSeen(window.localStorage.getItem(STORAGE_KEY));
  } catch {
    return NOTHING_SEEN;
  }
}

export function saveTourSeen(seen: TourSeen): void {
  try {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(seen));
  } catch {
    // Storage blocked: the tour may show again on the next visit.
  }
}
