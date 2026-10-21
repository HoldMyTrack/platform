/**
 * The date-range slider's rules (`docs/SPEC.md` FR-6), as plain values: how many activity-days
 * fit, where a date's knob sits, what a knob move or a pan does to the selection, and how the
 * window follows a range. Android: `map/SliderRules.kt`; both run `testdata/client-rules`.
 *
 * Days are the window's activity-days (`YYYY-MM-DD`, ascending). Boundary b is where slot b begins
 * (0..n). A date before the window is -1 and one after it n + 1, off-screen, unless there's no
 * history on that side, where it sits on the edge: today with nothing recorded yet still has its
 * end knob on the right edge.
 */
import type { DateRange } from './dateMath.ts';

/** « »'s width, its gap to the track, and the track's inset each side, in CSS px or dp. */
const PAGE = 22;
const GAP = 6;
const PAD = 8;
/** The narrowest activity-day: two knobs a day apart stay apart. */
const MIN_SLOT = 24;
export const MIN_DAYS = 7;
export const MAX_DAYS = 31;
/** « » show only if the track still holds this many days beside them. */
const BUTTONS_FROM = 12;

/** How many activity-days the window holds at `width` (the room for « track »), and whether « »
 *  show: always for a fine pointer, which has no swipe; otherwise only where they leave enough
 *  track. */
export function sliderLayout(width: number, finePointer: boolean): { buttons: boolean; days: number } {
  const withButtons = width - 2 * (PAGE + GAP) - 2 * PAD;
  const buttons = finePointer || Math.floor(withButtons / MIN_SLOT) >= BUTTONS_FROM;
  const track = buttons ? withButtons : width - 2 * PAD;
  return { buttons, days: Math.min(Math.max(Math.floor(track / MIN_SLOT), MIN_DAYS), MAX_DAYS) };
}

export interface SliderWindow {
  days: readonly string[];
  canPanEarlier: boolean;
  canPanLater: boolean;
}

/** The boundaries of `range`'s two knobs: start where its first day begins, end where its last
 *  one ends. */
export function sliderBoundaries({ days, canPanEarlier, canPanLater }: SliderWindow, range: DateRange): { start: number; end: number } {
  const n = days.length;
  const first = days[0];
  const last = days[n - 1];
  if (first === undefined || last === undefined) return { start: 0, end: 0 };
  let start: number;
  if (range.from < first) start = canPanEarlier ? -1 : 0;
  else {
    const i = days.findIndex((d) => d >= range.from);
    start = i === -1 ? (canPanLater ? n + 1 : n) : i;
  }
  let end: number;
  if (range.to > last) end = canPanLater ? n + 1 : n;
  else if (range.to < first) end = canPanEarlier ? -1 : 0;
  else end = days.filter((d) => d <= range.to).length;
  return { start, end };
}

/** One knob moved to boundary `b`, a slot from the other (pushing it if needed). A knob that ends
 *  up where it already was keeps its own date, which may lie off-screen or in a gap between
 *  activity-days; only a knob that moved takes a slot's date. */
export function sliderMoveKnob(window: SliderWindow, range: DateRange, knob: 'start' | 'end', b: number): DateRange {
  const { days } = window;
  const n = days.length;
  if (n === 0) return range;
  const { start: s0, end: e0 } = sliderBoundaries(window, range);
  let s = s0;
  let e = e0;
  if (knob === 'start') {
    s = Math.min(Math.max(b, 0), n - 1);
    e = Math.max(e0, s + 1);
  } else {
    e = Math.min(Math.max(b, 1), n);
    s = Math.min(s0, e - 1);
  }
  return { from: s === s0 ? range.from : days[s]!, to: e === e0 ? range.to : days[e - 1]! };
}

export interface SliderTick {
  boundary: number;
  /** Tall where a month starts. */
  kind: 'day' | 'month';
  /** The month (1..12) labelled from this boundary: each month start, and the first month in
   *  view at the left edge. */
  month: number | null;
}

/** A tick on every boundary 0..n; the outer two are plain. */
export function sliderTicks(days: readonly string[]): SliderTick[] {
  if (days.length === 0) return [];
  return Array.from({ length: days.length + 1 }, (_, b) => {
    const before = days[b - 1];
    const after = days[b];
    const month = (date: string) => Number(date.slice(5, 7));
    if (before === undefined) return { boundary: b, kind: 'day' as const, month: month(after!) };
    if (after === undefined || before.slice(0, 7) === after.slice(0, 7)) return { boundary: b, kind: 'day' as const, month: null };
    return { boundary: b, kind: 'month' as const, month: month(after) };
  });
}

/** A pan has landed on the window `days`: the knobs it was carrying (`start`, `end`) move onto
 *  the new edges, the other one pushed if they'd cross. */
export function sliderPanLand(days: readonly string[], range: DateRange, start: boolean, end: boolean): DateRange {
  const first = days[0];
  const last = days[days.length - 1];
  if (first === undefined || last === undefined) return range;
  let next = range;
  if (start) next = { from: first, to: next.to < first ? first : next.to };
  if (end) next = { from: next.from > last ? last : next.from, to: last };
  return next;
}

/** Where a window of `windowDays` over `count` loaded days, now from `left`, moves to show the
 *  days `first`..`last` (indices): as little as it takes; for a run longer than the window, its
 *  edge on the `dir` side (-1 the start, 1 the end). */
export function sliderWindowFit(count: number, windowDays: number, left: number, first: number, last: number, dir: -1 | 1): number {
  const maxStart = Math.max(0, count - windowDays);
  let next = left;
  if (last - first + 1 > windowDays) next = dir < 0 ? first : last - windowDays + 1;
  else if (first < left) next = first;
  else if (last >= left + windowDays) next = last - windowDays + 1;
  return Math.min(Math.max(next, 0), maxStart);
}
