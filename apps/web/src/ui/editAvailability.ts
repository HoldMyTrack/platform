/** Why the Edit window's Track or Photos tab can't be used for its activities, as a message key,
 *  or null. Whether one activity allows it is the server's answer (the list's `track_edit` and
 *  `photos`); the client adds only the rule that depends on the selection. */
import type { Activity } from '../api';
import type { MessageKey } from '../i18n/en';

const TRACK_EDIT_MESSAGES: Record<NonNullable<Activity['trackEdit']>, MessageKey> = {
  pending: 'activities.edit_track_processing',
  private: 'activities.private_title',
  no_original: 'activities.edit_track_no_original',
  bad_times: 'activities.edit_track_bad_times',
};

/** The Track tab edits one activity the server allows (FR-5.14). */
export function editTrackBlocker(activities: readonly Activity[] | null): MessageKey | null {
  if (activities === null || activities.length !== 1) return 'activities.edit_track_check_one';
  const reason = activities[0]!.trackEdit;
  return reason ? (TRACK_EDIT_MESSAGES[reason] ?? null) : null;
}

/** Photos belong to one activity and need a track to sit on (FR-16.1). */
export function editPhotosBlocker(activities: readonly Activity[] | null): MessageKey | null {
  if (activities === null || activities.length !== 1) return 'photos.check_one';
  return activities[0]!.photos === 'private' ? 'activities.private_title' : null;
}
