/**
 * Whether the Activities tab shows the first-run panel (docs/SPEC.md FR-5.18): a real account
 * with no activities at all. `hasActivities` is null until the account's first page of
 * activity-days has come back, and the panel waits for it, so an account with history never
 * flashes it. A demo always has activities and can't import.
 */
export function showsFirstRun(isDemo: boolean, hasActivities: boolean | null): boolean {
  return !isDemo && hasActivities === false;
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