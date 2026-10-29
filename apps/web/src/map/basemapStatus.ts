/**
 * Whether the map says its basemap can't be reached (docs/SPEC.md FR-4.5): a network that blocks
 * the tile host leaves the globe empty with no error of its own, since a stalled request never
 * fails. Its cases are `testdata/client-rules/basemap-status.json`.
 */

export type BasemapStatus = 'loading' | 'loaded' | 'unreachable';

/** How long the map waits on screen for its first basemap tile. */
export const BASEMAP_WAIT_MS = 15_000;

export function basemapStatus(loaded: boolean, failed: boolean, waitedMs: number): BasemapStatus {
  if (loaded) return 'loaded';
  return failed || waitedMs >= BASEMAP_WAIT_MS ? 'unreachable' : 'loading';
}
