import { knownTimeZone } from './timeZone.ts';

/**
 * Plain YYYY-MM-DD day strings: the Dates filter's ends (dateFilter.ts) and "today". They sort
 * lexicographically in chronological order, so comparing and clamping dates needs no helper.
 */

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
