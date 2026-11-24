/**
 * Whether the Tracks panel's Download (`docs/SPEC.md` FR-17.2) can take its target, as plain
 * values, so the button is disabled and says why before a request the server would refuse.
 */

import { MAX_DOWNLOAD_TRACKS } from '../limits.ts';

/** Checked in the panel can pass the download limit while the map pans. */
export { MAX_DOWNLOAD_TRACKS };

export type DownloadBlock<T> = { kind: 'too_many'; count: number } | { kind: 'pending' | 'private'; track: T };

/**
 * Why the target can't be downloaded, or null when it can: more tracks than one download takes,
 * else the first Pending track, else the first entirely inside Private locations. A missing or
 * unreadable original only the server can tell; its refusal names the track. Its cases are
 * `testdata/client-rules/download-block.json`, which Android runs too.
 */
export function downloadBlock<T extends { pending: boolean; private: boolean }>(
  target: readonly T[],
  max: number = MAX_DOWNLOAD_TRACKS,
): DownloadBlock<T> | null {
  if (target.length > max) return { kind: 'too_many', count: target.length };
  const pending = target.find((track) => track.pending);
  if (pending) return { kind: 'pending', track: pending };
  const privateTrack = target.find((track) => track.private);
  if (privateTrack) return { kind: 'private', track: privateTrack };
  return null;
}
