import type { TrackDetail } from '../api.ts';
import type { MessageKey } from '../i18n/en.ts';
import { MAX_TRACK_DESCRIPTION_LEN, MAX_TRACK_NAME_LEN, MAX_TRACK_TYPE_LEN, MAX_PHOTO_CAPTION_LEN } from '../limits.ts';
import { waitingPhotos, type PhotoDraft } from './photoDraft.ts';

/** What `updateTrack` writes — the PATCH endpoint is a full replace of all three. */
export interface TrackFields {
  trackType: string;
  name: string;
  description: string;
}

/**
 * The field writes Save has to make: one per track whose fields, as the form now has them,
 * differ from what the server holds — what an earlier Save in this window wrote (`written`),
 * else what the window opened with. One track takes all three fields from the form. A group
 * takes only the type, and keeps each track's own name and description: the endpoint
 * replaces all three, so a group edit still sends them unchanged. An empty type on a group
 * ("Mixed types") keeps each track's own type too. A track whose last
 * write failed (`unsure`) is written whatever it holds: the server may have taken it and the
 * answer been lost. The cases are
 * `testdata/client-rules/edit-writes.json`.
 */
export function fieldWrites(
  tracks: readonly Pick<TrackDetail, 'id' | 'trackType' | 'name' | 'description'>[],
  single: boolean,
  typedType: string,
  typedName: string,
  description: string,
  written: ReadonlyMap<string, TrackFields>,
  unsure: ReadonlySet<string>,
): { id: string; fields: TrackFields }[] {
  const type = typedType.trim();
  const name = typedName.trim();
  return tracks.flatMap((track) => {
    const held = written.get(track.id) ?? {
      trackType: track.trackType,
      name: track.name ?? '',
      description: track.description ?? '',
    };
    const fields = single ? { trackType: type, name, description } : { ...held, trackType: type || held.trackType };
    const same = fields.trackType === held.trackType && fields.name === held.name && fields.description === held.description;
    return same && !unsure.has(track.id) ? [] : [{ id: track.id, fields }];
  });
}

/** Why Save can't go ahead yet: the message, its values, and the tab that shows the problem. */
interface SaveProblem {
  key: MessageKey;
  vars?: { max: number };
  tab: 'track' | 'photos';
}

/**
 * The first reason Save refuses, before anything is written, or null: the Route tab's fields
 * first (a type, unless a group keeps its mixed types, and every field within the server's
 * limit), then the Photos tab's draft (every new photo placed, every caption within its limit).
 * Lengths are of the trimmed text, as the server counts them, except the description's, which
 * is sent as typed.
 */
export function saveProblem(form: {
  trackType: string;
  name: string;
  description: string;
  mixedTypes: boolean;
  photoDraft: PhotoDraft;
}): SaveProblem | null {
  const type = form.trackType.trim();
  if (!type && !form.mixedTypes) return { key: 'edit.type_required', tab: 'track' };
  if (type.length > MAX_TRACK_TYPE_LEN) return { key: 'edit.type_too_long', vars: { max: MAX_TRACK_TYPE_LEN }, tab: 'track' };
  if (form.name.trim().length > MAX_TRACK_NAME_LEN) return { key: 'edit.name_too_long', vars: { max: MAX_TRACK_NAME_LEN }, tab: 'track' };
  if (form.description.length > MAX_TRACK_DESCRIPTION_LEN) {
    return { key: 'edit.description_too_long', vars: { max: MAX_TRACK_DESCRIPTION_LEN }, tab: 'track' };
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