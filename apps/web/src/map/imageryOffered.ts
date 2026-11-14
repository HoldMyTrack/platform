/**
 * Whether the web offers Satellite (docs/SPEC.md FR-4.10): the build configures imagery, and the
 * server hasn't paused it near the imagery plan's monthly limit. `server` is null until the server
 * has answered, or after a read failed: the build's word stands then, and the map's own fallback
 * (satelliteStatus.ts) covers imagery that doesn't load.
 */
export function satelliteOffered(configured: boolean, server: boolean | null): boolean {
  return configured && server !== false;
}
