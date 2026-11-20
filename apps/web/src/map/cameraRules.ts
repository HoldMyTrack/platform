/** Where the camera goes when a Trip's list lands (FR-13.6), as plain values. */
import type { BBox, Track } from '../api.ts';

type Framable = Pick<Track, 'bbox' | 'pending' | 'private'>;

/** Whether a fit over several tracks frames this one (SPEC.md FR-5.8): not Pending, and not
 *  Private, whose bbox is its location's circle, which only focusing that row flies to. */
function framed<T extends Framable>(track: T): track is T & { bbox: BBox } {
  return track.bbox !== null && !track.pending && !track.private;
}

/** The boxes a fit over several tracks frames, in the tracks' order (the `fitBoxes` rule). */
export function fitBoxes(tracks: readonly Framable[]): BBox[] {
  return tracks.filter(framed).map((a) => a.bbox);
}

/** The boxes Show on map frames (the `selectionBoxes` rule): one track's own, a Private one's
 *  circle included; several, fitBoxes's, so a circle never joins other tracks' routes. */
export function selectionBoxes(tracks: readonly Framable[]): BBox[] {
  if (tracks.length === 1) return tracks[0]!.bbox === null ? [] : [tracks[0]!.bbox];
  return fitBoxes(tracks);
}

/**
 * A Trip's first loaded list fits all of it, a trip; a URL view (`#…`) keeps the camera. Returns
 * null to wait for a later list (a Trip with nothing drawn yet), else the tracks to fit,
 * empty for none. Without a Trip the opening view is openingView.ts's.
 */
export function firstListFit(tracks: readonly Track[], tripId: string | null, urlView: boolean): Track[] | null {
  if (tripId === null || urlView) return [];
  const drawn = tracks.filter(framed);
  return drawn.length === 0 ? null : drawn;
}