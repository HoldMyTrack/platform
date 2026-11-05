/**
 * The demo bar's rule (DemoBar.tsx): a demo session shows it until × hides it, for as long as a
 * demo session lasts (docs/SPEC.md FR-2.1), so a visitor back days later is told again where
 * they are. The hidden-until time is the browser's, kept in localStorage.
 */
export const DEMO_BAR_HIDE_MS = 24 * 60 * 60 * 1000;

/** Whether the bar shows: a demo session whose bar isn't hidden at `now`. */
export function demoBarShown(isDemo: boolean, hiddenUntil: number | null, now: number): boolean {
  return isDemo && (hiddenUntil === null || now >= hiddenUntil);
}

/** The stored hidden-until time, or null for none or anything unreadable. */
export function readHiddenUntil(stored: string | null): number | null {
  if (stored === null) return null;
  const n = Number(stored);
  return Number.isFinite(n) && n > 0 ? n : null;
}