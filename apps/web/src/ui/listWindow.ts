/**
 * The rows of a long list worth rendering: those in view and a few either side, for a list whose
 * rows share one height. The Activities tab renders up to 1,000 (docs/SPEC.md FR-5.19), every one
 * again on each reload of the area, which stalled the page for a quarter of a second at a time;
 * the rest are spacers the height of the rows they stand for.
 */

/** Rows rendered past each edge of the view, so a quick scroll doesn't show blank space first. */
export const OVERSCAN = 8;

/** Rows `start` (inclusive) to `end` (exclusive) of `count`, for a view `viewHeight` tall
 *  scrolled to `scrollTop`. */
export function listWindow(count: number, rowHeight: number, scrollTop: number, viewHeight: number): { start: number; end: number } {
  if (count === 0 || rowHeight <= 0) return { start: 0, end: count };
  const first = Math.floor(Math.max(0, scrollTop) / rowHeight);
  const last = Math.ceil((Math.max(0, scrollTop) + Math.max(0, viewHeight)) / rowHeight);
  return { start: Math.max(0, Math.min(count, first - OVERSCAN)), end: Math.min(count, last + OVERSCAN) };
}

/** The scroll position that puts row `index` in the middle of a view `viewHeight` tall, within
 *  the list's `count` rows. */
export function scrollTopFor(index: number, count: number, rowHeight: number, viewHeight: number): number {
  const centred = index * rowHeight - (viewHeight - rowHeight) / 2;
  return Math.max(0, Math.min(centred, count * rowHeight - viewHeight));
}
