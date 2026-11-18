import { useMemo, useRef, useState } from 'react';
import { Pencil, Play, Send, Trash2 } from 'lucide-react';
import { deleteTrip, removeTripTracks, type Track, type Trip, type TripTotals } from '../api.ts';
import { TrackRow } from './TrackRow.tsx';
import { useListWindow } from './useListWindow.ts';
import { ConfirmDialog } from './ConfirmDialog.tsx';
import { SendCopyDialog } from './SendCopyDialog.tsx';
import { TripDialog } from './TripDialog.tsx';
import { TripInboxItems } from './TripInboxItems.tsx';
import { folderClick, isFolded } from './tripFold.ts';
import type { TripInboxState } from './useTripInbox.ts';
import { formatTrackType, formatDuration, formatTotalDistance } from './format.ts';
import { useUnitSystem, type UnitSystem } from './units.ts';
import { t, tn } from '../i18n/index.ts';

/** A Trip's numbers, or one type's share of them, in one line — "3 tracks · 58 km · 3h 26m
 *  moving". */
function tripStatsLine(totals: TripTotals, system: UnitSystem): string {
  return t('trips.stats', {
    tracks: tn('tracks.count', totals.count),
    distance: formatTotalDistance(totals.distanceMeters, system),
    moving: formatDuration(totals.movingSeconds),
  });
}

interface TripsTabProps {
  readOnly: boolean;
  /** Newest first — useStories. */
  trips: Trip[];
  tripsReady: boolean;
  tripsError: string | null;
  /** Copies of Trips others sent the account, and the accepted ones still arriving — useStoryInbox. */
  inbox: TripInboxState;
  /** The open Trip's id — MapView's storyId. At most one is open, and once the list has
   *  loaded, one always is (MapView opens the newest). */
  openId: string | null;
  /** The open Trip as `GET /v2/trips/{id}` last returned it (useStory) — its whole-Trip
   *  statistics for the footer. */
  openTrip: Trip | null;
  /** Why the open Trip couldn't be read — a `?trip=` that doesn't exist or isn't this account's. */
  openError: string | null;
  /** The open Trip's tracks, all of them — MapView's list. */
  tracks: Track[];
  tracksLoading: boolean;
  tracksError: string | null;
  focusedId: string | null;
  hoveredId: string | null;
  onOpen: (id: string) => void;
  onFocus: (id: string) => void;
  onClearFocus: () => void;
  onHoverTrack: (id: string | null) => void;
  /** Renamed or re-described with a folder's pencil — the Trip as the server returned it. */
  onEdited: (trip: Trip) => void;
  /** Deleted with a folder's trash, once the server has deleted it. */
  onDeleted: (id: string) => void;
  /** A track taken out of the open Trip with its row's ×, once the server has done it — the
   *  Trip as the server returned it. */
  onTrackRemoved: (trip: Trip, trackId: string) => void;
}

/**
 * The Tracks panel's Trips tab (`SPEC.md` FR-13.6): the copies others sent, to accept or
 * decline (FR-13.7), then every Trip as a folder, newest first,
 * exactly one of them open. Opening one is viewing it — MapView narrows the drawn tracks and the
 * list to it, whatever area and Dates the Tracks tab has, and this tab shows that list inside the folder and the whole
 * Trip's statistics in the footer. A row previews on hover and focuses on click, like the
 * Tracks tab's, and its × takes the track out of the Trip (`DELETE
 * /v2/trips/{id}/tracks`) — here, where the Trip is open, rather than where tracks are
 * picked, which is where they go in (AddToTripMenu.tsx). A folder's pencil and trash rename and
 * delete that Trip. A click on the open Trip's folder folds its list away or back
 * (tripFold.ts); the Trip stays open.
 */
export function TripsTab({
  readOnly,
  trips,
  tripsReady,
  tripsError,
  inbox,
  openId,
  openTrip,
  openError,
  tracks,
  tracksLoading,
  tracksError,
  focusedId,
  hoveredId,
  onOpen,
  onFocus,
  onClearFocus,
  onHoverTrack,
  onEdited,
  onDeleted,
  onTrackRemoved,
}: TripsTabProps) {
  const system = useUnitSystem();
  const [editing, setEditing] = useState<Trip | null>(null);
  const [deleting, setDeleting] = useState<Trip | null>(null);
  const [sending, setSending] = useState<Trip | null>(null);
  // The row being taken out of the open Trip, and why the last one couldn't be.
  const [removing, setRemoving] = useState<string | null>(null);
  const [removeError, setRemoveError] = useState<string | null>(null);
  const [foldedId, setFoldedId] = useState<string | null>(null);

  async function remove(tripId: string, trackId: string) {
    if (removing !== null) return;
    setRemoving(trackId);
    setRemoveError(null);
    try {
      onTrackRemoved(await removeTripTracks(tripId, [trackId]), trackId);
    } catch (err) {
      setRemoveError(err instanceof Error ? err.message : t('common.something_wrong'));
    } finally {
      setRemoving(null);
    }
  }
  // The open Trip's rows render only those in view, as the Tracks tab's do: a Trip has no
  // size cap, and every hover re-rendered all of its rows.
  const listRef = useRef<HTMLUListElement>(null);
  const rowsRef = useRef<HTMLUListElement>(null);
  const focusedIndex = useMemo(() => (focusedId === null ? -1 : tracks.findIndex((a) => a.id === focusedId)), [tracks, focusedId]);
  const { start, end, rowHeight } = useListWindow(listRef, rowsRef, tracks.length, { id: focusedId, index: focusedIndex });

  const editTitle = readOnly ? t('trips.demo_edit') : t('trips.edit');
  const deleteTitle = readOnly ? t('trips.demo_delete') : t('trips.delete');
  const sendTitle = readOnly ? t('trips.demo_send') : t('trips.send');
  const removeTitle = readOnly ? t('trips.demo_remove') : t('trips.remove');
  const openListed = openId !== null && trips.some((s) => s.id === openId);

  return (
    <>
      <ul className="trips-tab" data-testid="trips-list" ref={listRef}>
        <TripInboxItems inbox={inbox} />
        {openError && !openListed && <li className="tracks-panel__note tracks-panel__note--error">{openError}</li>}
        {trips.map((listed) => {
          const open = listed.id === openId;
          const expanded = open && !isFolded(foldedId, openId);
          // The open Trip's own copy is the fresher one — its numbers follow edits made since.
          const trip = open && openTrip?.id === listed.id ? openTrip : listed;
          return (
            <li
              key={trip.id}
              className={`trips-tab__trip${open ? ' trips-tab__trip--open' : ''}${expanded ? ' trips-tab__trip--expanded' : ''}`}
            >
              <div className={`trips-tab__folder${open ? ' tracks-panel__row--current' : ''}`}>
                <button
                  type="button"
                  className="trips-tab__toggle"
                  aria-expanded={expanded}
                  data-testid="trips-tab-toggle"
                  onClick={() => {
                    const click = folderClick(foldedId, openId, trip.id);
                    setFoldedId(click.foldedId);
                    if (!click.open) return;
                    setRemoveError(null);
                    onOpen(trip.id);
                  }}
                >
                  <Play size={12} className="trips-tab__chevron" aria-hidden="true" />
                  <span className="trips-tab__name">{trip.name}</span>
                </button>
                <button
                  type="button"
                  className="tracks-panel__edit tracks-panel__row-action"
                  disabled={readOnly}
                  onClick={() => setEditing(trip)}
                  aria-label={`${editTitle}: ${trip.name}`}
                  title={editTitle}
                >
                  <Pencil size={14} />
                </button>
                <button
                  type="button"
                  className="tracks-panel__edit tracks-panel__row-action"
                  disabled={readOnly}
                  onClick={() => setSending(trip)}
                  aria-label={`${sendTitle}: ${trip.name}`}
                  title={sendTitle}
                >
                  <Send size={14} />
                </button>
                <button
                  type="button"
                  className="tracks-panel__delete tracks-panel__row-action"
                  disabled={readOnly}
                  onClick={() => setDeleting(trip)}
                  aria-label={`${deleteTitle}: ${trip.name}`}
                  title={deleteTitle}
                >
                  <Trash2 size={14} />
                </button>
              </div>
              {expanded && (
                // A click on the body's own empty space clears the selection, as on the
                // Tracks tab's list.
                <div
                  className="trips-tab__body"
                  onClick={(e) => {
                    const target = e.target as HTMLElement;
                    if (target === e.currentTarget || target.classList.contains('tracks-panel__spacer')) onClearFocus();
                  }}
                >
                  {trip.from !== null && <p className="trips-tab__from">{t('trips.from', { from: trip.from })}</p>}
                  {trip.description !== '' && <p className="trips-tab__description">{trip.description}</p>}
                  {removeError && <p className="tracks-panel__note tracks-panel__note--error">{removeError}</p>}
                  <ul className="trips-tab__rows" ref={rowsRef}>
                    {start > 0 && <li className="tracks-panel__spacer" style={{ height: start * rowHeight }} aria-hidden="true" />}
                    {tracks.slice(start, end).map((track) => (
                      <TrackRow
                        key={track.id}
                        track={track}
                        system={system}
                        focused={focusedId === track.id}
                        hovered={hoveredId === track.id}
                        hidden={false}
                        openTripId={trip.id}
                        remove={{
                          label: removeTitle,
                          disabled: readOnly || removing !== null,
                          onRemove: () => void remove(trip.id, track.id),
                        }}
                        onOpenTrip={(id) => {
                          setFoldedId(null);
                          setRemoveError(null);
                          onOpen(id);
                        }}
                        onFocus={() => onFocus(track.id)}
                        onHover={onHoverTrack}
                      />
                    ))}
                    {end < tracks.length && (
                      <li className="tracks-panel__spacer" style={{ height: (tracks.length - end) * rowHeight }} aria-hidden="true" />
                    )}
                    {tracksLoading && <li className="tracks-panel__note">{t('common.loading')}</li>}
                    {tracksError && !tracksLoading && (
                      <li className="tracks-panel__note tracks-panel__note--error">{tracksError}</li>
                    )}
                    {!tracksLoading && !tracksError && tracks.length === 0 && (
                      <li className="tracks-panel__note">
                        {trip.stats.count === 0 ? t('trips.no_tracks') : t('tracks.none_match')}
                      </li>
                    )}
                  </ul>
                </div>
              )}
            </li>
          );
        })}
        {!tripsReady && !tripsError && trips.length === 0 && <li className="tracks-panel__note">{t('common.loading')}</li>}
        {tripsError && <li className="tracks-panel__note tracks-panel__note--error">{tripsError}</li>}
        {tripsReady && trips.length === 0 && <li className="tracks-panel__note">{t('trips.empty')}</li>}
      </ul>

      {/* The whole Trip's statistics (FR-13.1). */}
      {openTrip && openTrip.id === openId && (
        <div className="tracks-panel__footer trips-tab__stats" data-testid="trips-tab-stats">
          {openTrip.stats.count > 0 ? (
            <>
              <p className="trips-tab__stats-line">{tripStatsLine(openTrip.stats, system)}</p>
              <table className="trips-tab__types" aria-label={t('trips.by_type')}>
                <tbody>
                  {openTrip.stats.byType.map((type) => (
                    <tr key={type.trackType}>
                      <th scope="row">{formatTrackType(type.trackType)}</th>
                      <td>{tripStatsLine(type, system)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </>
          ) : (
            <p className="trips-tab__stats-line">{t('trips.no_tracks')}</p>
          )}
        </div>
      )}

      {editing && (
        <TripDialog mode="edit" trip={editing} onSaved={onEdited} onClose={() => setEditing(null)} />
      )}

      {sending && <SendCopyDialog trip={sending} onClose={() => setSending(null)} />}

      {deleting && (
        <ConfirmDialog
          title={t('trips.delete_title')}
          message={t('trips.delete_confirm', { name: deleting.name })}
          confirmLabel={t('trips.delete_button')}
          busyLabel={t('common.deleting')}
          onConfirm={async () => {
            await deleteTrip(deleting.id);
            onDeleted(deleting.id);
          }}
          onClose={() => setDeleting(null)}
        />
      )}
    </>
  );
}