import { knownTimeZone } from './timeZone.ts';

/**
 * Plain YYYY-MM-DD day strings: the date range the Activities tab's slider selects, and "today".
 * The strings sort lexicographically in chronological order, so comparing and clamping dates
 * needs no helper at all, and the slider pages by days-with-activity (useActivityDays), which is
 * index arithmetic over an array rather than calendar arithmetic.
 */

/** The selected date range, both ends inclusive — MapView's `selectedRange`, the list and
 *  tracks filter while the Activities tab is showing. */
export interface DateRange {
  from: string;
  to: string;
}

/** The calendar day at [now] in [zone], the account's, which decides "today" (docs/SPEC.md
 *  FR-1.7); the browser's own when the zone is missing or this browser doesn't know it. Asked
 *  each time it's needed, not once: a tab left open runs past midnight. */
export function todayIn(zone: string | undefined, now: Date = new Date()): string {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: knownTimeZone(zone),
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(now);
  const part = (type: string) => parts.find((p) => p.type === type)?.value ?? '';
  return `${part('year')}-${part('month')}-${part('day')}`;
}
