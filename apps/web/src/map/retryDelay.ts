/**
 * The wait before a poll's next request, after `failures` failed ones in a row: `base` while they
 * answer, doubling with each failure up to `max`, so an API that's down isn't asked every couple
 * of seconds for as long as the tab stays open.
 */
export function retryDelay(failures: number, base: number, max: number): number {
  return Math.min(base * 2 ** Math.max(0, failures), max);
}
