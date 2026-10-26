import { NOTHING_SEEN, type CardId, type TourSeen } from './tourRules.ts';

/** What the tour has shown in this browser (docs/SPEC.md FR-4.18). A per-browser record like the Layers picks (map/overlays.ts): the demo is one account shared by every visitor. */
const STORAGE_KEY = 'hmt.tour';
const CARDS: readonly CardId[] = ['fog', 'heatmap', 'stories'];

export function loadTourSeen(): TourSeen {
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    if (!raw) return NOTHING_SEEN;
    const saved = JSON.parse(raw) as Partial<TourSeen>;
    return { tour: saved.tour === true, cards: CARDS.filter((c) => Array.isArray(saved.cards) && saved.cards.includes(c)) };
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