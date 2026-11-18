/**
 * Whether the Tracks tab shows the first-run panel (docs/SPEC.md FR-5.10): a real account
 * with no tracks at all. `hasTracks` is null until the account's first page of
 * track-days has come back, and the panel waits for it, so an account with history never
 * flashes it. A demo always has tracks and can't import.
 */
export function showsFirstRun(isDemo: boolean, hasTracks: boolean | null): boolean {
  return !isDemo && hasTracks === false;
}

/**
 * How many imports the header's Upload menu has in flight, from its `data-in-flight`
 * attribute (static/upload.js): files still uploading plus imports still processing. Anything
 * unreadable is none.
 */
export function importsInFlight(attribute: string | null | undefined): number {
  const n = Number(attribute);
  return Number.isInteger(n) && n > 0 ? n : 0;
}