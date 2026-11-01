import type { Activity } from '../api';
import type { MessageKey } from '../i18n/en';
import { MAX_ACTIVITY_DESCRIPTION_LEN, MAX_ACTIVITY_NAME_LEN, MAX_ACTIVITY_TYPE_LEN, MAX_PHOTO_CAPTION_LEN } from '../limits.ts';
import { waitingPhotos, type PhotoDraft } from './photoDraft.ts';

/** What `updateActivity` writes — the PATCH endpoint is a full replace of all three. */
export interface ActivityFields {
  activityType: string;
  name: string;
  description: string;
}

/**
 * The field writes Save has to make: one per activity whose fields, as the form now has them,
 * differ from what the server holds — what an earlier Save in this window wrote (`written`),
 * else what the window opened with. One activity takes all three fields from the form. A group
 * takes only the type, and keeps each activity's own name and description: the endpoint
 * replaces all three, so a group edit still sends them unchanged. An empty type on a group
 * ("Mixed types") keeps each activity's own type too.
 */
export function fieldWrites(
  activities: readonly Pick<Activity, 'id' | 'activityType' | 'name' | 'description'>[],
  single: boolean,
  type: string,
  name: string,
  description: string,
  written: ReadonlyMap<string, ActivityFields>,
): { id: string; fields: ActivityFields }[] {
  return activities.flatMap((activity) => {
    const held = written.get(activity.id) ?? {
      activityType: activity.activityType,
      name: activity.name ?? '',
      description: activity.description ?? '',
    };
    const fields = single ? { activityType: type, name, description } : { ...held, activityType: type || held.activityType };
    const same = fields.activityType === held.activityType && fields.name === held.name && fields.description === held.description;
    return same ? [] : [{ id: activity.id, fields }];
  });
}

/** Why Save can't go ahead yet: the message, its values, and the tab that shows the problem. */
export interface SaveProblem {
  key: MessageKey;
  vars?: { max: number };
  tab: 'activity' | 'photos';
}

/**
 * The first reason Save refuses, before anything is written, or null: the Activity tab's fields
 * first (a type, unless a group keeps its mixed types, and every field within the server's
 * limit), then the Photos tab's draft (every new photo placed, every caption within its limit).
 * Lengths are of the trimmed text, as the server counts them, except the description's, which
 * is sent as typed.
 */
export function saveProblem(form: {
  activityType: string;
  name: string;
  description: string;
  mixedTypes: boolean;
  photoDraft: PhotoDraft;
}): SaveProblem | null {
  const type = form.activityType.trim();
  if (!type && !form.mixedTypes) return { key: 'edit.type_required', tab: 'activity' };
  if (type.length > MAX_ACTIVITY_TYPE_LEN) return { key: 'edit.type_too_long', vars: { max: MAX_ACTIVITY_TYPE_LEN }, tab: 'activity' };
  if (form.name.trim().length > MAX_ACTIVITY_NAME_LEN) return { key: 'edit.name_too_long', vars: { max: MAX_ACTIVITY_NAME_LEN }, tab: 'activity' };
  if (form.description.length > MAX_ACTIVITY_DESCRIPTION_LEN) {
    return { key: 'edit.description_too_long', vars: { max: MAX_ACTIVITY_DESCRIPTION_LEN }, tab: 'activity' };
  }
  const draft = form.photoDraft;
  if (waitingPhotos(draft).length > 0) return { key: 'photos.place_first', tab: 'photos' };
  const captions = [
    ...draft.added.map((p) => p.caption),
    ...Object.values(draft.changed).flatMap((c) => (c.caption === undefined ? [] : [c.caption])),
  ];
  if (captions.some((c) => c.trim().length > MAX_PHOTO_CAPTION_LEN)) {
    return { key: 'photos.caption_too_long', vars: { max: MAX_PHOTO_CAPTION_LEN }, tab: 'photos' };
  }
  return null;
}