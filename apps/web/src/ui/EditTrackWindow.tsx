import { useCallback, useEffect, useRef, useState } from 'react';
import { useWindowFocus } from './useWindowFocus.ts';
import { onTabListKeyDown } from './tabKeys.ts';
import type { Map as MapLibreMap } from 'maplibre-gl';
import { deletePhoto, saveTrackRouteEdit, SplitHidesPartError, updateTrack, updatePhoto, uploadPhoto, type Track, type TrackDetail, type Photo, type RouteEdit } from '../api.ts';
import type { PhotoMarkerOverlay } from '../map/photos.ts';
import { draftIsEmpty, draftSize, EMPTY_DRAFT, isoSeconds, type PhotoDraft } from './photoDraft.ts';
import { fieldWrites, saveProblem, type TrackFields } from './editSave.ts';
import { MAX_TRACK_DESCRIPTION_LEN, MAX_TRACK_NAME_LEN, MAX_TRACK_TYPE_LEN } from '../limits.ts';
import type { TypeFacet } from './trackFacets.ts';
import { TrackTypePicker } from './TrackTypePicker.tsx';
import { ConfirmDialog } from './ConfirmDialog.tsx';
import { formatStartedAt } from './format.ts';
import { PhotosTab } from './PhotosTab.tsx';
import { RouteEditor } from './RouteEditor.tsx';
import { t, tn } from '../i18n/index.ts';


export type EditTab = 'track' | 'route' | 'photos';

/** The Route tab's unsaved session: the edit Save sends, and the point to split at, if any. */
type RoutePending = { edit: RouteEdit | null; splitAt: number | null };

/**
 * The Edit window (docs/SPEC.md FR-5.5, IMPLEMENTATION.md §4.7.7) — reached from the header toolbar's Edit button
 * (TracksPanel.tsx) over whatever's currently checked, floating over the map. Two tabs
 * behind one shared Save and Cancel:
 *
 *  - **Track** — Type, Name, and Description. `tracks` is always at least one, and the
 *    form branches on its length: exactly one edits all three; more than one edits Type only —
 *    Name and Description have nothing to set consistently across several different tracks
 *    at once, so they render disabled with a tooltip explaining why rather than silently doing
 *    nothing or (worse) overwriting every checked track's name/description with one value.
 *  - **Track** — RouteEditor.tsx, over exactly one track with a finished track;
 *    `routeUnavailable` names why not otherwise, as the disabled tab's tooltip. Opening it the
 *    first time starts MapView's track session (`onStartRoute`: the other tracks hidden, the
 *    camera on this one), which then lasts until the window closes; the editor stays mounted
 *    behind the Route tab, so switching back and forth loses nothing.
 *  - **Photos** — PhotosTab.tsx, over exactly one track with a track; `photosUnavailable`
 *    names why not otherwise. Its changes are a draft (photoDraft.ts) kept here, like the track
 *    edit: new photos prepared in the browser with their places settled, moves, captions and
 *    deletes, written by the same Save. Mounted on first open and kept.
 *
 * Save writes what changed — the fields first (skipped when they're as they were), then the
 * route edit (skipped when the Route tab did nothing) — and closes. If a later write fails after earlier ones landed, the window stays open with the
 * error, a retry skips what's already written, and `onClose` still reports it so the list picks
 * it up. Cancel discards whatever wasn't written; Escape does too, after asking, when there is
 * any. Both wait, with Save, while the Photos tab is still preparing picked photos.
 *
 * Floating, not a modal `<dialog>` as the Track form alone once was: the Route tab edits on
 * the map, and a modal would make the map inert. MapView makes the Tracks panel inert
 * instead while the window is open — the window edits the checked group, which
 * must not change underneath it.
 *
 * Type is TrackTypePicker.tsx — the same searchable picker as Settings' Country and
 * Timezone, listing this account's existing types, but open-ended: activity_type is free
 * text, not a controlled vocabulary (§4.7). Picking an existing type is a
 * convenience, never a constraint: typing something nobody has used before offers an "Add" row
 * that saves it exactly as typed, to every checked track. Name is optional — a track
 * with none falls back to its start datetime as the row's primary line; it's never parsed from
 * a source file, only typed in here, one track at a time.
 */
interface EditTrackWindowProps {
  map: MapLibreMap;
  /** At least one — the checked group, whatever its size. */
  tracks: TrackDetail[];
  /** Every distinct activity_type already in this account's loaded tracks, with counts —
   *  the same facets the Type filter is built from (trackFacets.ts), reused as the Type
   *  picker's list rather than recomputed. */
  knownTypes: TypeFacet[];
  /** Why the Route tab is disabled, or null when `tracks` is one editable track. */
  routeUnavailable: string | null;
  onStartRoute: (track: Track) => void;
  /** Why the Photos tab is disabled, or null when `tracks` is one track with a track. */
  photosUnavailable: string | null;
  /** The single track's saved photos — MapView owns them, since they're also its markers —
   *  and where to report how the draft changes the markers. */
  photos: {
    photos: readonly Photo[];
    error: string | null;
    /** Reads the saved photos again: a Save that stops partway has taken what landed out of the draft. */
    reload: () => void;
    onOverlay: (overlay: PhotoMarkerOverlay | null) => void;
  };
  /** The tab showing changed — MapView hides the photo markers on the Route tab. */
  onTabChange: (tab: EditTab) => void;
  /** `saved`: something was written, so the list reloads. `routeApplied`: a route edit was sent, so the row now reads
   *  Pending until its reprocess lands. */
  onClose: (result: EditWindowResult) => void;
}

export interface EditWindowResult {
  saved: boolean;
  routeApplied: boolean;
  /** Photos were uploaded, changed or deleted, so MapView refetches them. */
  photosSaved: boolean;
}

export function EditTrackWindow({
  map,
  tracks,
  knownTypes,
  routeUnavailable,
  onStartRoute,
  photosUnavailable,
  photos,
  onTabChange,
  onClose,
}: EditTrackWindowProps) {
  const single = tracks.length === 1 ? tracks[0]! : null;
  const [tab, setTab] = useState<EditTab>('track');
  const [routeStarted, setRouteStarted] = useState(false);
  const [photosStarted, setPhotosStarted] = useState(false);
  const [photoDraft, setPhotoDraft] = useState<PhotoDraft>(EMPTY_DRAFT);
  const [photoProgress, setPhotoProgress] = useState<{ done: number; total: number } | null>(null);
  const [confirmDiscard, setConfirmDiscard] = useState(false);
  // Any photo write landed — a later failure or Cancel still has to report it.
  const photosSaved = useRef(false);
  // New photos' local thumbnails are object URLs; whatever's left unsaved goes with the window.
  const draftRef = useRef(photoDraft);
  draftRef.current = photoDraft;
  useEffect(() => () => draftRef.current.added.forEach((p) => URL.revokeObjectURL(p.thumbSrc)), []);
  // A change to the photos answers whatever Save last refused about them — but not mid-Save,
  // when the draft shrinks as each write lands.
  useEffect(() => {
    if (!saving) setError(null);
  }, [photoDraft]);
  // A group whose tracks share one type starts on it; a mixed group starts empty ("Mixed
  // types"), and stays that way unless a type is picked — empty keeps each track's own type.
  const mixedTypes = tracks.some((a) => a.activityType !== tracks[0]!.activityType);
  const [activityType, setActivityType] = useState(mixedTypes ? '' : tracks[0]!.activityType);
  const [name, setName] = useState(single?.name ?? '');
  const [description, setDescription] = useState(single?.description ?? '');
  const [routePending, setRoutePending] = useState<RoutePending | null>(null);
  const [saving, setSaving] = useState(false);
  // A split that would leave a part inside a Private location (FR-5.9): the server's
  // explanation, asked about before saving again with allowHidden.
  const [hiddenSplitWarning, setHiddenSplitWarning] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  // Photos still being prepared (PhotosTab's Add): Save would leave the rest of the batch
  // behind, and Cancel would drop it without asking.
  const [preparing, setPreparing] = useState(false);
  // Each track's fields as an earlier Save in this window wrote them — what the server holds
  // now, where the `tracks` prop still has what the window opened with. A retry after a later
  // failure compares against these, and a Cancel still reports them so the list picks them up.
  const written = useRef(new Map<string, TrackFields>());

  const onRouteChange = useCallback((pending: RoutePending | null) => {
    setRoutePending(pending);
    setError(null);
  }, []);

  const cancel = useCallback(() => {
    onClose({ saved: written.current.size > 0, routeApplied: false, photosSaved: photosSaved.current });
  }, [onClose]);

  // Anything Cancel would throw away: a field edit, a route edit, a photo change.
  const unsaved =
    !draftIsEmpty(photoDraft) ||
    routePending !== null ||
    fieldWrites(tracks, single !== null, activityType.trim(), name.trim(), description, written.current).length > 0;
  const unsavedRef = useRef(unsaved);
  unsavedRef.current = unsaved;

  useEffect(() => {
    if (saving || preparing) return;
    const onKeyDown = (event: KeyboardEvent) => {
      // Not an Escape meant for a dialog of its own, such as the discard confirmation below.
      if ((event.target as Element | null)?.closest?.('dialog')) return;
      if (event.key !== 'Escape' || event.defaultPrevented) return;
      // Escape is a reflex, and an edit can be a lot of typing, chopping or sliding: ask first.
      // preventDefault, or the browser's own Escape handling closes the confirmation the moment
      // it opens — it's the topmost dialog by the time this key's default action runs.
      if (unsavedRef.current) {
        event.preventDefault();
        setConfirmDiscard(true);
      } else cancel();
    };
    document.addEventListener('keydown', onKeyDown);
    return () => document.removeEventListener('keydown', onKeyDown);
  }, [saving, preparing, cancel]);

  // Leaving the page — a reload, a closed tab, a link in the header — would lose unsaved photo
  // changes with no way back, so the browser asks first while there are any, or while they're
  // being written.
  const photosAtRisk = saving || !draftIsEmpty(photoDraft);
  useEffect(() => {
    if (!photosAtRisk) return;
    const onBeforeUnload = (event: BeforeUnloadEvent) => {
      event.preventDefault();
      event.returnValue = '';
    };
    window.addEventListener('beforeunload', onBeforeUnload);
    return () => window.removeEventListener('beforeunload', onBeforeUnload);
  }, [photosAtRisk]);

  function openTab(next: EditTab) {
    setTab(next);
    onTabChange(next);
    if (next === 'photos') setPhotosStarted(true);
    if (next === 'route' && !routeStarted && single) {
      setRouteStarted(true);
      onStartRoute(single);
    }
  }

  async function save() {
    // Nothing is written until every tab's input passes (editSave.ts).
    const problem = saveProblem({ activityType, name, description, mixedTypes, photoDraft });
    if (problem) {
      setError(t(problem.key, problem.vars));
      openTab(problem.tab);
      return;
    }
    const trimmedType = activityType.trim();
    const trimmedName = name.trim();
    setSaving(true);
    setError(null);
    try {
      // Sequential, not Promise.all, matching TracksPanel.tsx's own group delete: a
      // hand-checked group is a handful of rows, not bulk-import scale. Each write is recorded
      // as it lands, so a failure partway leaves the rest for a retry.
      for (const { id, fields } of fieldWrites(tracks, single !== null, trimmedType, trimmedName, description, written.current)) {
        await updateTrack(id, fields);
        written.current.set(id, fields);
      }
      if (single && !draftIsEmpty(photoDraft)) await savePhotos(single.id, photoDraft);
      if (single && routePending) {
        await saveTrackRouteEdit(single.id, routePending.edit, routePending.splitAt);
        onClose({ saved: true, routeApplied: true, photosSaved: photosSaved.current });
        return;
      }
      onClose({ saved: written.current.size > 0, routeApplied: false, photosSaved: photosSaved.current });
    } catch (err) {
      if (photosSaved.current) photos.reload();
      if (err instanceof SplitHidesPartError) {
        // Everything before the track is written; the question is about the split alone.
        setHiddenSplitWarning(err.message);
        setSaving(false);
        setPhotoProgress(null);
        return;
      }
      setError(err instanceof Error ? err.message : t('edit.save_failed'));
      setSaving(false);
      setPhotoProgress(null);
    }
  }

  // Writes the photo draft, one request at a time: uploads (each at the place it settled on),
  // then moves and captions, then deletes. Each write that lands leaves the draft, so a retry
  // after a failure picks up where it stopped.
  async function savePhotos(trackId: string, draft: PhotoDraft) {
    const total = draftSize(draft);
    let done = 0;
    const step = () => setPhotoProgress({ done: ++done, total });
    setPhotoProgress({ done, total });
    for (const photo of draft.added) {
      await uploadPhoto(trackId, photo.prepared, isoSeconds(photo.routeAt!), photo.caption.trim() || undefined);
      photosSaved.current = true;
      URL.revokeObjectURL(photo.thumbSrc);
      setPhotoDraft((d) => ({ ...d, added: d.added.filter((p) => p.key !== photo.key) }));
      step();
    }
    for (const [id, change] of Object.entries(draft.changed)) {
      if (draft.deleted.includes(id)) continue;
      await updatePhoto(id, {
        caption: change.caption?.trim(),
        routeAt: change.routeAt === undefined ? undefined : isoSeconds(change.routeAt),
      });
      photosSaved.current = true;
      setPhotoDraft((d) => {
        const changed = { ...d.changed };
        delete changed[id];
        return { ...d, changed };
      });
      step();
    }
    for (const id of draft.deleted) {
      await deletePhoto(id);
      photosSaved.current = true;
      setPhotoDraft((d) => {
        const changed = { ...d.changed };
        delete changed[id];
        return { ...d, changed, deleted: d.deleted.filter((x) => x !== id) };
      });
      step();
    }
  }

  const windowRef = useRef<HTMLElement>(null);
  useWindowFocus(windowRef);

  const namedFieldsDisabledReason = single ? undefined : t('edit.multi_reason');
  // As Save would leave them.
  const photoCount = photos.photos.length - photoDraft.deleted.length + photoDraft.added.length;

  return (
    <section ref={windowRef} tabIndex={-1} className="edit-route edit-window" aria-label={t('edit.title_one')} data-testid="edit-track-window">
      <header className="edit-route__head">
        <span className="edit-route__title">{single ? t('edit.title_one') : tn('edit.title_many', tracks.length)}</span>
        <span className="edit-route__subtitle">
          {single ? single.name?.trim() || formatStartedAt(single.startedAt, single.timezone) : t('edit.multi_subtitle')}
        </span>
      </header>

      <div className="edit-window__tabs" role="tablist" aria-label={t('edit.title_one')}>
        <button
          type="button"
          role="tab"
          onKeyDown={onTabListKeyDown}
          className="edit-window__tab"
          aria-selected={tab === 'track'}
          tabIndex={tab === 'track' ? 0 : -1}
          onClick={() => openTab('track')}
          data-testid="edit-tab-track"
        >
          {t('edit.tab_track')}
        </button>
        <button
          type="button"
          role="tab"
          onKeyDown={onTabListKeyDown}
          className="edit-window__tab"
          aria-selected={tab === 'route'}
          tabIndex={tab === 'route' ? 0 : -1}
          disabled={routeUnavailable !== null}
          title={routeUnavailable ?? undefined}
          onClick={() => openTab('route')}
          data-testid="edit-tab-route"
        >
          {t('edit.tab_route')}
          {routePending && <span className="edit-window__tab-dot" aria-hidden="true" />}
        </button>
        <button
          type="button"
          role="tab"
          onKeyDown={onTabListKeyDown}
          className="edit-window__tab"
          aria-selected={tab === 'photos'}
          tabIndex={tab === 'photos' ? 0 : -1}
          disabled={photosUnavailable !== null}
          title={photosUnavailable ?? undefined}
          onClick={() => openTab('photos')}
          data-testid="edit-tab-photos"
        >
          {t('photos.tab')}
          {photosUnavailable === null && photoCount > 0 && <span className="edit-window__tab-count">{photoCount}</span>}
          {!draftIsEmpty(photoDraft) && <span className="edit-window__tab-dot" aria-hidden="true" />}
        </button>
      </div>

      <div className="edit-window__panel" role="tabpanel" hidden={tab !== 'track'}>
        {/* A <div>, not a <label> like the fields below: a label wrapping the picker would
            forward every click inside its popover (search box included) to the trigger. */}
        <div className="settings-page__section">
          <span className="settings-page__label" id="edit-track-type-label">
            {t('tracks.type')}
          </span>
          <TrackTypePicker
            value={activityType}
            onChange={setActivityType}
            known={knownTypes}
            labelledBy="edit-track-type-label"
            maxLength={MAX_TRACK_TYPE_LEN}
            emptyLabel={t('edit.type_mixed')}
          />
        </div>

        <label className="settings-page__section" title={namedFieldsDisabledReason}>
          <span className="settings-page__label">{t('edit.name')}</span>
          <input
            className="settings-page__input"
            type="text"
            value={name}
            onChange={(e) => setName(e.target.value)}
            maxLength={MAX_TRACK_NAME_LEN}
            placeholder={t('edit.name_placeholder')}
            disabled={!single}
          />
        </label>

        <label className="settings-page__section" title={namedFieldsDisabledReason}>
          <span className="settings-page__label">{t('edit.description')}</span>
          <textarea
            className="settings-page__input edit-window__description"
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            maxLength={MAX_TRACK_DESCRIPTION_LEN}
            placeholder={t('edit.description_placeholder')}
            rows={4}
            disabled={!single}
          />
        </label>
      </div>


      {routeStarted && single && (
        <div className="edit-window__panel" role="tabpanel" hidden={tab !== 'route'}>
          <RouteEditor map={map} track={single} active={tab === 'route'} busy={saving} onChange={onRouteChange} />
        </div>
      )}

      {photosStarted && single && photosUnavailable === null && (
        <div className="edit-window__panel" role="tabpanel" hidden={tab !== 'photos'}>
          <PhotosTab
            track={single}
            photos={photos.photos}
            error={photos.error}
            draft={photoDraft}
            setDraft={setPhotoDraft}
            active={tab === 'photos'}
            busy={saving}
            onPreparingChange={setPreparing}
            onOverlay={photos.onOverlay}
          />
        </div>
      )}

      {error && <p className="edit-route__error">{error}</p>}
      <div className="edit-route__row edit-route__row--footer">
        <span className="edit-route__spacer" aria-hidden="true" />
        <button type="button" className="edit-route__btn" disabled={saving || preparing} onClick={cancel}>
          {t('common.cancel')}
        </button>
        <button
          type="button"
          className="edit-route__btn edit-route__btn--primary"
          disabled={saving || preparing}
          onClick={() => void save()}
          data-testid="edit-save"
        >
          {saving && photoProgress
            ? t('photos.saving_n', { n: Math.min(photoProgress.done + 1, photoProgress.total), total: photoProgress.total })
            : saving
              ? t('common.saving')
              : t('common.save')}
        </button>
      </div>
      {confirmDiscard && (
        <ConfirmDialog
          title={t('edit.discard_title')}
          message={t('edit.discard_message')}
          confirmLabel={t('edit.discard')}
          cancelLabel={t('edit.keep_editing')}
          onConfirm={async () => cancel()}
          onClose={() => setConfirmDiscard(false)}
        />
      )}
      {hiddenSplitWarning !== null && single && routePending && (
        <ConfirmDialog
          title={t('edit_route.split_hidden_title')}
          message={hiddenSplitWarning}
          confirmLabel={t('edit_route.split_hidden_confirm')}
          busyLabel={t('common.saving')}
          onConfirm={async () => {
            await saveTrackRouteEdit(single.id, routePending.edit, routePending.splitAt, true);
            onClose({ saved: true, routeApplied: true, photosSaved: photosSaved.current });
          }}
          onClose={() => setHiddenSplitWarning(null)}
        />
      )}
    </section>
  );
}
