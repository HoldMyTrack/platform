import type { UnitSystem } from './units';

/**
 * What format.ts decides before the language writes it: which number, how many decimals, which
 * unit or message. No i18n in it, so Android's `FormatParts.kt` runs the same cases,
 * `testdata/client-rules/distance-parts.json`, `total-distance-parts.json` and
 * `duration-parts.json`; the strings themselves are each platform's.
 */

const METERS_PER_MILE = 1609.344;

/** A number to write in the language's digits, with `minDecimals`–`maxDecimals` decimals and
 *  thousands grouped or not, followed by `unit`. */
export interface DistanceParts {
  value: number;
  minDecimals: number;
  maxDecimals: number;
  grouping: boolean;
  unit: 'km' | 'mi';
}

/** A duration message: `duration.hm` ("3h 52m"), `duration.m` ("43m") or `duration.s` ("20s"). */
export type DurationParts =
  | { key: 'duration.hm'; args: { h: number; m: number } }
  | { key: 'duration.m'; args: { m: number } }
  | { key: 'duration.s'; args: { s: number } };

function converted(meters: number, system: UnitSystem): number {
  return system === 'imperial' ? meters / METERS_PER_MILE : meters / 1000;
}

function unitOf(system: UnitSystem): 'km' | 'mi' {
  return system === 'imperial' ? 'mi' : 'km';
}

/** An activity's distance: always one decimal, never grouped. */
export function distanceParts(meters: number, system: UnitSystem): DistanceParts {
  return { value: converted(meters, system), minDecimals: 1, maxDecimals: 1, grouping: false, unit: unitOf(system) };
}

/** A range's total: one decimal below 10 (km or mi), so a short history never reads as a flat
 *  "0 km", and whole units from 10 up. */
export function totalDistanceParts(meters: number, system: UnitSystem): DistanceParts {
  const value = converted(meters, system);
  return { value, minDecimals: 0, maxDecimals: value < 10 ? 1 : 0, grouping: true, unit: unitOf(system) };
}

/** Hours and minutes from an hour up, minutes from a minute, else seconds. */
export function durationParts(seconds: number): DurationParts {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  if (h > 0) return { key: 'duration.hm', args: { h, m } };
  if (m > 0) return { key: 'duration.m', args: { m } };
  return { key: 'duration.s', args: { s: seconds } };
}
