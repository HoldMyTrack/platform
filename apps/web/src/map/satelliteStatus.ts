/**
 * Whether satellite imagery is loading on this device (docs/SPEC.md FR-4.10): an ad blocker, a
 * firewall or a network that refuses the imagery host leaves Satellite mode with its fills hidden
 * and nothing under them. "failed" when an imagery request failed before any tile arrived, or 15
 * seconds of Satellite on screen passed without one; "loaded" once one has, which a later tile
 * arriving reaches from "failed" too. The cases are `testdata/client-rules/satellite-status.json`.
 */

export type SatelliteStatus = 'loading' | 'loaded' | 'failed';

/** How long Satellite waits on screen for its first imagery tile. */
export const SATELLITE_WAIT_MS = 15_000;

export function satelliteStatus(loaded: boolean, failed: boolean, waitedMs: number): SatelliteStatus {
  if (loaded) return 'loaded';
  return failed || waitedMs >= SATELLITE_WAIT_MS ? 'failed' : 'loading';
}

/** Whether the map looks like Satellite: its fills hidden for the imagery and its roads dimmed.
 *  Failed imagery draws the map as with Satellite off, though the imagery layer stays on to
 *  notice a tile arriving. */
export function satelliteLook(on: boolean, status: SatelliteStatus): boolean {
  return on && status !== 'failed';
}
