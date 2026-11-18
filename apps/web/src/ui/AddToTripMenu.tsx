import { useEffect, useMemo, useRef, useState } from 'react';
import { BookPlus, Check, Plus } from 'lucide-react';
import { addTripTracks, type Track, type Trip } from '../api.ts';
import { TripDialog } from './TripDialog.tsx';
import { useTrips } from './useTrips.ts';
import { t, tn } from '../i18n/index.ts';
import { useDismiss } from './useDismiss.ts';

interface AddToTripMenuProps {
  readOnly: boolean;
  /** The toolbar's target — the checked group, else the selected row (MapView's toolbarTargetIds). */
  target: Track[];
  /** The target as the toolbar's tooltips name it ("3 checked tracks"), null with none. */
  targetName: string | null;
  /** "3 checked tracks (58 km)" — Create trip's description of what it's made of. */
  summary: string;
  /** A Trip just made of the target — MapView opens it on the Trips tab. */
  onCreated: (trip: Trip) => void;
  /** An existing Trip the target was just added to, as the server returned it. */
  onAdded: (trip: Trip) => void;
}

/**
 * The Tracks toolbar's Add to trip (`SPEC.md` FR-13): the one place tracks go into a
 * Trip — where they're picked. A menu over the toolbar's target: "New trip…" (TripDialog.tsx
 * in its create mode, a Trip made of the target), then every Trip, newest first, fetched each
 * time the menu opens (useTrips). Clicking a Trip adds the target to it with one
 * `POST /v2/trips/{id}/tracks` and closes the menu; a Trip already holding all of the
 * target is ticked and can't be picked. Taking a track out of a Trip is the Trips tab's
 * (TripsTab.tsx), where the Trip is open.
 */
export function AddToTripMenu({ readOnly, target, targetName, summary, onCreated, onAdded }: AddToTripMenuProps) {
  const [open, setOpen] = useState(false);
  const [creating, setCreating] = useState(false);
  const [adding, setAdding] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const ref = useRef<HTMLDivElement>(null);
  const trips = useTrips(open);

  useDismiss(ref, open, setOpen);

  // A new target is a new question: close the menu rather than leave it answering the old one.
  const targetKey = target.map((a) => a.id).join(',');
  useEffect(() => {
    setOpen(false);
    setError(null);
  }, [targetKey]);

  const ids = target.map((a) => a.id);
  // Whether each Trip holds all of the target, worked out once while the menu is open: a
  // checked group of 1,000 against a Trip of 5,000 is 5 million compares as a list search.
  // Keyed on the ids, not `target`, which the toolbar builds afresh on every render.
  const held = useMemo(() => {
    const result = new Map<string, boolean>();
    if (!open) return result;
    const targetIds = targetKey === '' ? [] : targetKey.split(',');
    for (const trip of trips.trips) {
      const members = new Set(trip.trackIds);
      result.set(trip.id, targetIds.every((id) => members.has(id)));
    }
    return result;
  }, [open, trips.trips, targetKey]);
  const title = readOnly
    ? t('trips.demo_add')
    : targetName === null
      ? t('tracks.no_target')
      : t('trips.add_target', { target: targetName });

  async function add(trip: Trip) {
    if (adding !== null) return;
    setAdding(trip.id);
    setError(null);
    try {
      const updated = await addTripTracks(trip.id, ids);
      setOpen(false);
      onAdded(updated);
    } catch (err) {
      setError(err instanceof Error ? err.message : t('common.something_wrong'));
    } finally {
      setAdding(null);
    }
  }

  return (
    <div className="trip-menu" ref={ref}>
      <button
        type="button"
        className="tracks-panel__add-trip"
        data-testid="add-to-trip"
        disabled={readOnly || targetName === null}
        aria-haspopup="menu"
        aria-expanded={open}
        aria-label={title}
        title={title}
        onClick={() => {
          setError(null);
          setOpen((o) => !o);
        }}
      >
        <BookPlus size={16} />
      </button>
      {open && (
        <div className="trip-menu__panel" role="group" aria-label={title} data-testid="add-to-trip-menu">
          <button
            type="button"
            className="trip-menu__item trip-menu__item--new"
            onClick={() => {
              setOpen(false);
              setCreating(true);
            }}
          >
            <Plus size={14} aria-hidden="true" />
            <span className="trip-menu__name">{t('trips.new')}</span>
          </button>
          {(trips.trips.length > 0 || !trips.ready) && <div className="trip-menu__divider" aria-hidden="true" />}
          {!trips.ready && !trips.error && <p className="trip-menu__note">{t('common.loading')}</p>}
          {trips.error && <p className="trip-menu__note trip-menu__note--error">{trips.error}</p>}
          {trips.ready && (
            <div className="trip-menu__list">
              {trips.trips.map((trip) => {
                const holdsAll = held.get(trip.id) ?? false;
                return (
                  <button
                    key={trip.id}
                    type="button"
                    className="trip-menu__item"
                    disabled={holdsAll || adding !== null}
                    title={holdsAll ? t('trips.holds_all') : undefined}
                    onClick={() => void add(trip)}
                  >
                    <span className="trip-menu__check" aria-hidden="true">
                      {holdsAll && <Check size={14} />}
                    </span>
                    <span className="trip-menu__name">{trip.name}</span>
                    <span className="trip-menu__count">
                      {adding === trip.id ? t('trips.adding') : tn('tracks.count', trip.trackIds.length)}
                    </span>
                  </button>
                );
              })}
            </div>
          )}
          {error && <p className="trip-menu__note trip-menu__note--error">{error}</p>}
        </div>
      )}
      {creating && (
        <TripDialog mode="create" trackIds={ids} summary={summary} onSaved={onCreated} onClose={() => setCreating(false)} />
      )}
    </div>
  );
}
