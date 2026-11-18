/** Why the Edit window's Track or Photos tab can't be used for its tracks, as a message key,
 *  or null. Whether one track allows it is the server's answer (`GET /v1/activities/{id}`'s
 *  `track_edit` and `photos`); the client adds only the rule that depends on the selection. */
import type { TrackDetail } from '../api.ts';
import type { MessageKey } from '../i18n/en.ts';

const TRACK_EDIT_MESSAGES: Record<NonNullable<TrackDetail['routeEdit']>, MessageKey> = {
  pending: 'tracks.edit_route_processing',
  private: 'tracks.private_title',
  no_original: 'tracks.edit_route_no_original',
  bad_times: 'tracks.edit_route_bad_times',
};

/** The Route tab edits one track the server allows (FR-5.7). */
export function editRouteBlocker(tracks: readonly TrackDetail[] | null): MessageKey | null {
  if (tracks === null || tracks.length !== 1) return 'tracks.edit_route_check_one';
  const reason = tracks[0]!.routeEdit;
  return reason ? (TRACK_EDIT_MESSAGES[reason] ?? null) : null;
}

/** Photos belong to one track and need a track to sit on (FR-15.1). */
export function editPhotosBlocker(tracks: readonly TrackDetail[] | null): MessageKey | null {
  if (tracks === null || tracks.length !== 1) return 'photos.check_one';
  return tracks[0]!.photos === 'private' ? 'tracks.private_title' : null;
}
