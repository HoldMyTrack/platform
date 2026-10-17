const knownZones = new Map<string, boolean>();

/**
 * `zone` as a `timeZone` option, or undefined (the browser's own) when this browser's tz data
 * doesn't know it — a zone newer than the browser would otherwise throw a RangeError.
 */
export function knownTimeZone(zone: string | undefined): string | undefined {
  if (!zone) return undefined;
  let known = knownZones.get(zone);
  if (known === undefined) {
    try {
      new Intl.DateTimeFormat('en', { timeZone: zone });
      known = true;
    } catch {
      known = false;
    }
    knownZones.set(zone, known);
  }
  return known ? zone : undefined;
}

let accountZone: string | undefined;

/** The signed-in account's zone, which `activityTimeZone` falls back to. App.tsx sets it once a
 *  session is confirmed; a Settings change reaches the app on its next load. */
export function setAccountTimeZone(zone: string | undefined): void {
  accountZone = zone;
}

/**
 * The zone an activity's times are shown in (IMPLEMENTATION.md §4.30): `own`, the one it was
 * recorded in, which the server names from its own, possibly newer, tz data; else the
 * account's; else undefined, the browser's. Android's `ActivityZone.kt` runs the same cases,
 * `testdata/client-rules/activity-zone.json`.
 */
export function activityTimeZone(own: string | undefined, account: string | undefined = accountZone): string | undefined {
  return knownTimeZone(own) ?? knownTimeZone(account);
}
