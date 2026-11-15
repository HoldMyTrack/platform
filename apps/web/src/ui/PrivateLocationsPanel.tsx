import { useCallback, useEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { Pencil, Trash2 } from 'lucide-react';
import type { Map as MapLibreMap } from 'maplibre-gl';
import {
  deletePrivateLocation,
  hiddenActivityCount,
  listPrivateLocations,
  savePrivateLocation,
  type PrivateLocation,
} from '../api';
import { labelInsertionPoint } from '../map/layers';
import { PRIVATE_LOCATION_MAX_NAME_LEN, PRIVATE_LOCATION_MAX_RADIUS_M, PRIVATE_LOCATION_MIN_RADIUS_M } from '../limits';
import {
  attachPrivateLocationsHandlers,
  clearPrivateLocations,
  ensurePrivateLocationsLayer,
  PRIVATE_LOCATIONS_MIN_PLACE_ZOOM,
  setPrivateLocationsData,
  type PrivateLocationsClick,
} from '../map/privateLocations';
import { ConfirmDialog } from './ConfirmDialog';
import { highlightedCircle, pickAction, type PickIntent } from './privateLocationPick';
import { elevationUnitLabel, metersToFeet } from './format';
import { useUnitSystem } from './units';
import { lang, t, tn } from '../i18n';

/**
 * The Activities panel's Privacy tab (FR-7.1): the account's circles listed, each with its own
 * Edit and Delete, and a Create that puts a new circle in the middle of the map. Clicking a row
 * flies to its circle and highlights it, as clicking the circle on the map does; Edit opens the
 * editor, a window floating over the map like the Edit window's (portaled into the map's
 * container, since this tab lives in the side panel), where its center drags, a slider sets its
 * radius, and Save or Cancel closes it. With the editor open, clicking another circle switches
 * the editor to it. The circles are drawn, and clickable, for exactly as long as this is
 * mounted: switching tabs, or to Fog (which unmounts the whole panel), clears them and drops an
 * unsaved edit. Save
 * and Delete go straight to the server, which reprocesses every activity the change could clip
 * — `onChanged` has MapView reload the list so those rows show Pending straight away. The footer
 * counts the activities they hide entirely, the list's Private rows; it's read when the tab opens,
 * so a change shows there once reprocessing ends and the tab is opened again.
 *
 * Read-only for the demo account: its circle is listed, shown and highlighted, nothing is editable.
 */
export interface PrivateLocationsPanelProps {
  map: MapLibreMap;
  readOnly: boolean;
  onChanged: () => void;
  /** The editor window just opened — on a phone, the panel's sheet collapses out of its way. */
  onEditorOpen: () => void;
}

/** The circle being edited — a saved one (with its id) or a new one not saved yet. */
interface Draft {
  id?: string;
  name: string;
  lon: number;
  lat: number;
  radiusM: number;
}

const DEFAULT_RADIUS_M = 200;

function sameDraft(draft: Draft, saved: PrivateLocation | undefined): boolean {
  return (
    saved !== undefined &&
    draft.name.trim() === saved.name &&
    draft.lon === saved.lon &&
    draft.lat === saved.lat &&
    draft.radiusM === saved.radiusM
  );
}

function toDraft(location: PrivateLocation): Draft {
  return { id: location.id, name: location.name, lon: location.lon, lat: location.lat, radiusM: location.radiusM };
}

export function PrivateLocationsPanel({ map, readOnly, onChanged, onEditorOpen }: PrivateLocationsPanelProps) {
  const system = useUnitSystem();
  const [locations, setLocations] = useState<PrivateLocation[] | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [hidden, setHidden] = useState<number | null>(null);
  const [draft, setDraft] = useState<Draft | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [deleting, setDeleting] = useState<PrivateLocation | null>(null);
  // Highlighted on the map without an editor open.
  const [focusedId, setFocusedId] = useState<string | null>(null);
  // A location picked while the open one has unsaved changes — waiting on "Discard changes?".
  const [switchTo, setSwitchTo] = useState<{ location: PrivateLocation; intent: PickIntent; fly: boolean } | null>(null);

  useEffect(() => {
    const controller = new AbortController();
    listPrivateLocations(controller.signal)
      .then(setLocations)
      .catch((err: unknown) => {
        if (!controller.signal.aborted) setLoadError(err instanceof Error ? err.message : String(err));
      });
    // Only a line of context: the tab works without it, so a failure leaves it out.
    hiddenActivityCount(controller.signal).then(setHidden, () => {});
    return () => controller.abort();
  }, []);

  // Draw, and redraw after a theme swap discards custom layers (styledata) — owned here, not
  // by MapView's reattachOverlays, since the overlay only exists while this tab is showing.
  useEffect(() => {
    const draw = () => {
      ensurePrivateLocationsLayer(map, labelInsertionPoint(map));
      setPrivateLocationsData(map, locations ?? [], highlightedCircle(locations, draft, focusedId), draft !== null);
    };
    draw();
    map.on('styledata', draw);
    return () => {
      map.off('styledata', draw);
    };
  }, [map, locations, draft, focusedId]);
  useEffect(() => () => clearPrivateLocations(map), [map]);

  const pickNow = useCallback(
    (location: PrivateLocation, intent: PickIntent, fly: boolean) => {
      if (fly) map.flyTo({ center: [location.lon, location.lat], zoom: Math.max(map.getZoom(), 14) });
      setFocusedId(location.id);
      setError(null);
      if (intent === 'edit') {
        setDraft(toDraft(location));
        onEditorOpen();
      } else setDraft(null);
    },
    [map, onEditorOpen],
  );
  // pickAction (privateLocationPick.ts) says when this asks first or leaves the editor as it is.
  const editorState = useRef({ draft, dirty: false, busy });
  const pick = useCallback(
    (location: PrivateLocation, intent: PickIntent, fly: boolean) => {
      const { draft, dirty, busy } = editorState.current;
      const action = pickAction({ open: draft !== null, id: draft?.id, dirty, busy }, location.id);
      // The map moves only once the pick goes through: flying ahead of "Discard changes?" would
      // leave the circle still being edited off screen on Keep editing.
      if (action === 'apply') pickNow(location, intent, fly);
      else if (action === 'confirm') setSwitchTo({ location, intent, fly });
      else if (action === 'keep') {
        if (fly) map.flyTo({ center: [location.lon, location.lat], zoom: Math.max(map.getZoom(), 14) });
        if (intent === 'edit') onEditorOpen();
      }
    },
    [map, onEditorOpen, pickNow],
  );

  function create() {
    const center = map.getCenter();
    // Zoomed out, a 200 m circle would be under a pixel — fly in on the same spot first.
    if (map.getZoom() < PRIVATE_LOCATIONS_MIN_PLACE_ZOOM) {
      map.flyTo({ center, zoom: PRIVATE_LOCATIONS_MIN_PLACE_ZOOM + 2 });
    }
    setDraft({ name: '', lon: center.lng, lat: center.lat, radiusM: DEFAULT_RADIUS_M });
    setFocusedId(null);
    setError(null);
    onEditorOpen();
  }

  // Attached once, reading everything else through this ref: re-attaching detaches first, and
  // detaching ends a drag in progress. A drag crossing a track re-renders this (the track's
  // hover goes up to MapView), with a new `pick` — found live, the circle stopped dead on the
  // first track it was dragged over.
  const clickInputs = useRef({ locations, pick, readOnly, editing: draft !== null });
  clickInputs.current = { locations, pick, readOnly, editing: draft !== null };
  const loaded = locations !== null;
  useEffect(() => {
    if (!loaded) return;
    return attachPrivateLocationsHandlers(map, {
      onClick: (target: PrivateLocationsClick) => {
        const { locations, pick, editing } = clickInputs.current;
        if (target.kind === 'saved') {
          const location = locations?.find((l) => l.id === target.id);
          // With the editor open, a click on another circle edits that one instead.
          if (location) pick(location, editing ? 'edit' : 'focus', false);
        } else if (target.kind === 'empty' && !editing) {
          setFocusedId(null);
        }
      },
      onDrag: (lngLat) => {
        if (!clickInputs.current.readOnly) setDraft((d) => (d ? { ...d, lon: lngLat.lng, lat: lngLat.lat } : d));
      },
    });
  }, [map, loaded]);

  const saved = draft?.id === undefined ? undefined : locations?.find((l) => l.id === draft.id);
  const dirty = draft !== null && !sameDraft(draft, saved);
  editorState.current = { draft, dirty, busy };

  async function save() {
    if (!draft) return;
    setBusy(true);
    setError(null);
    try {
      const result = await savePrivateLocation(
        { name: draft.name.trim(), lon: draft.lon, lat: draft.lat, radiusM: draft.radiusM },
        draft.id,
      );
      setLocations((prev) =>
        draft.id === undefined ? [...(prev ?? []), result] : (prev ?? []).map((l) => (l.id === result.id ? result : l)),
      );
      setDraft(null);
      setFocusedId(result.id);
      onChanged();
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setBusy(false);
    }
  }

  async function remove(id: string) {
    await deletePrivateLocation(id);
    setLocations((prev) => (prev ?? []).filter((l) => l.id !== id));
    // Unmounting the dialog skips its own onClose, so close it here too.
    setDeleting(null);
    setDraft((d) => (d?.id === id ? null : d));
    setFocusedId((f) => (f === id ? null : f));
    onChanged();
  }

  const unit = elevationUnitLabel(system);
  const radiusDisplay = (m: number) => Math.round(system === 'imperial' ? metersToFeet(m) : m).toLocaleString(lang);
  // The map's own container: `.map-root`, which Edit track's window is positioned in too.
  const windowHost = map.getContainer().parentElement;
  // With no locations, nothing can be hidden and the line would only be noise.
  const showHidden = hidden !== null && (locations?.length ?? 0) > 0;

  return (
    <div className="private-locations" data-testid="private-locations">
      {/* Laid out the way the Activities tab is — a toolbar strip, the same rows, a footer
          strip — so the three tabs read as one panel. */}
      {!readOnly && (
        <div className="activities-panel__toolbar">
          <button
            type="button"
            className="edit-track__btn edit-track__btn--primary"
            data-testid="private-locations-create"
            disabled={!locations}
            onClick={create}
          >
            {t('private.create')}
          </button>
        </div>
      )}

      <ul className="activities-panel__list">
        {loadError && <li className="activities-panel__note activities-panel__note--error">{loadError}</li>}
        {!locations && !loadError && <li className="activities-panel__note">{t('common.loading')}</li>}
        {locations?.length === 0 && <li className="activities-panel__note">{t('private.none')}</li>}
        {locations?.map((l) => {
          const label = l.name || t('private.unnamed');
          const highlighted = draft ? draft.id === l.id : focusedId === l.id;
          return (
            <li key={l.id} className={`activities-panel__row${highlighted ? ' activities-panel__row--selected' : ''}`}>
              <button
                type="button"
                className="activities-panel__text"
                aria-pressed={highlighted}
                onClick={() => pick(l, 'focus', true)}
              >
                <span className="activities-panel__title">{label}</span>
                <span className="activities-panel__meta">
                  {t('private.radius')} · {radiusDisplay(l.radiusM)} {unit}
                </span>
              </button>
              {!readOnly && (
                <>
                  <button
                    type="button"
                    className="activities-panel__edit activities-panel__row-action"
                    aria-label={t('private.edit_label', { label })}
                    title={t('private.edit_title')}
                    onClick={() => pick(l, 'edit', true)}
                  >
                    <Pencil size={14} />
                  </button>
                  <button
                    type="button"
                    className="activities-panel__delete activities-panel__row-action"
                    aria-label={t('private.delete_label', { label })}
                    title={t('common.delete')}
                    onClick={() => setDeleting(l)}
                  >
                    <Trash2 size={14} />
                  </button>
                </>
              )}
            </li>
          );
        })}
      </ul>

      {(!readOnly || showHidden) && (
        <div className="activities-panel__footer private-locations__footer">
          {showHidden && (
            <span className="private-locations__footer-note" data-testid="private-locations-hidden">
              {hidden === 0 ? t('private.hidden_none') : tn('private.hidden', hidden)}
            </span>
          )}
          {!readOnly && <span className="private-locations__footer-note">{t('private.reprocess_note')}</span>}
        </div>
      )}

      {draft &&
        !readOnly &&
        windowHost &&
        createPortal(
          <section
            className="edit-track private-locations__window"
            aria-label={t(draft.id === undefined ? 'private.new_title' : 'private.edit_title')}
            data-testid="private-locations-editor"
          >
            <header className="edit-track__head">
              <span className="edit-track__title">
                {t(draft.id === undefined ? 'private.new_title' : 'private.edit_title')}
              </span>
            </header>
            <label className="private-locations__field">
              <span className="activity-filters__label">{t('edit.name')}</span>
              <input
                className="settings-page__input"
                type="text"
                value={draft.name}
                maxLength={PRIVATE_LOCATION_MAX_NAME_LEN}
                placeholder={t('private.name_placeholder')}
                onChange={(e) => setDraft({ ...draft, name: e.target.value })}
              />
            </label>
            <label className="private-locations__field">
              <span className="activity-filters__head">
                <span className="activity-filters__label">{t('private.radius')}</span>
                <span className="activity-filters__readout">
                  {radiusDisplay(draft.radiusM)} {unit}
                </span>
              </span>
              <input
                type="range"
                className="private-locations__slider"
                min={PRIVATE_LOCATION_MIN_RADIUS_M}
                max={PRIVATE_LOCATION_MAX_RADIUS_M}
                step={10}
                value={draft.radiusM}
                onChange={(e) => setDraft({ ...draft, radiusM: Number(e.target.value) })}
              />
            </label>
            <p className="edit-track__note">{t('private.editor_note')}</p>
            {error && <p className="edit-track__error">{error}</p>}
            <div className="edit-track__row edit-track__row--footer">
              <span className="edit-track__spacer" />
              <button type="button" className="edit-track__btn" disabled={busy} onClick={() => setDraft(null)}>
                {t('common.cancel')}
              </button>
              <button
                type="button"
                className="edit-track__btn edit-track__btn--primary"
                disabled={busy || !dirty}
                onClick={() => void save()}
              >
                {busy ? t('common.saving') : t('common.save')}
              </button>
            </div>
          </section>,
          windowHost,
        )}

      {switchTo && (
        <ConfirmDialog
          title={t('edit.discard_title')}
          message={t('edit.discard_message')}
          confirmLabel={t('edit.discard')}
          cancelLabel={t('edit.keep_editing')}
          onConfirm={async () => pickNow(switchTo.location, switchTo.intent, switchTo.fly)}
          onClose={() => setSwitchTo(null)}
        />
      )}

      {deleting && (
        <ConfirmDialog
          title={t('private.delete_title')}
          message={t('private.delete_body')}
          confirmLabel={t('common.delete')}
          busyLabel={t('common.deleting')}
          onConfirm={() => remove(deleting.id)}
          onClose={() => setDeleting(null)}
        />
      )}
    </div>
  );
}
