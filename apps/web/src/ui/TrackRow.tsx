import { useRef, useState } from 'react';
import { Lock, X } from 'lucide-react';
import type { Track } from '../api.ts';
import { formatTrackType, formatDistance, formatDuration, formatStartedAt } from './format.ts';
import type { UnitSystem } from './units.ts';
import { typeIcon } from './trackKindIcon.ts';
import { t, tn } from '../i18n/index.ts';
import { useDismiss } from './useDismiss.ts';

/** A row's primary line: its user-entered name (§4.7) when it has one, else
 *  its start date/time — also how the toolbar names a single selected track. */
export function rowLabel(track: Track): string {
  return track.name?.trim() || formatStartedAt(track.startedAt, track.timezone);
}

interface TrackRowProps {
  track: Track;
  system: UnitSystem;
  focused: boolean;
  hovered: boolean;
  hidden: boolean;
  /** The Trip open on the Trips tab: every row there is in it, so only its other Trips
   *  are worth a badge. */
  openTripId?: string;
  /** The Tracks tab's checkbox; the Trips tab's rows have none. */
  checkbox?: { checked: boolean; onToggle: () => void };
  /** The Trips tab's Remove from trip — an × at the row's end, shown on hover or focus (always
   *  on a phone). */
  remove?: { label: string; disabled: boolean; onRemove: () => void };
  /** A Trip badge clicked — opens that Trip on the Trips tab (useTripNav's enterTrip). */
  onOpenTrip?: (id: string) => void;
  onFocus: () => void;
  onHover: (id: string | null) => void;
}

/** One track in a panel list — the Tracks tab's (TracksPanel.tsx, which documents the
 *  four row interactions) and an open Trip's on the Trips tab (TripsTab.tsx). */
export function TrackRow({
  track,
  system,
  focused,
  hovered,
  hidden,
  openTripId,
  checkbox,
  remove,
  onOpenTrip,
  onFocus,
  onHover,
}: TrackRowProps) {
  const isPending = track.pending;
  const otherTrips = track.trips.filter((s) => s.id !== openTripId);
  // A user-entered name (§4.7) leads; started_at is the fallback for a row
  // that has none — never the reverse, so a track's date doesn't disappear from the list
  // just because it also has a name (shown in the meta line below instead). Sorting itself is
  // untouched either way: the list's order comes entirely from the server's own
  // `ORDER BY started_at DESC`, never from this label.
  const displayName = track.name?.trim() || null;
  const label = rowLabel(track);
  const TypeIcon = typeIcon(track.trackType);
  const classes = ['tracks-panel__row'];
  // Only the selected row is bold on the map, so only it gets the row highlight — a checked
  // row's ticked box is its only mark.
  if (focused) classes.push('tracks-panel__row--current');
  if (hidden) classes.push('tracks-panel__row--hidden');
  if (isPending) classes.push('tracks-panel__row--pending');
  return (
    <li
      data-track-id={track.id}
      className={classes.join(' ')}
      onMouseEnter={() => onHover(track.id)}
      onMouseLeave={() => onHover(null)}
    >
      {checkbox && (
        <input
          type="checkbox"
          className="tracks-panel__checkbox"
          checked={checkbox.checked}
          // A pending row (§4.7.7) is disabled until its reprocess lands, except that an
          // already-checked one can still be unchecked.
          disabled={isPending && !checkbox.checked}
          aria-label={checkbox.checked ? t('tracks.row_uncheck', { label }) : t('tracks.row_check', { label })}
          onChange={checkbox.onToggle}
        />
      )}
      {/* Its kind's icon; the meta line names the type, so it's decoration to a screen reader. */}
      <TypeIcon className="tracks-panel__type-icon" size={18} aria-hidden="true" />
      <button
        type="button"
        className="tracks-panel__text"
        disabled={isPending}
        aria-pressed={focused}
        title={track.private ? t('tracks.private_title') : track.bbox === null ? t('tracks.no_route') : label}
        onClick={onFocus}
      >
        <span className={`tracks-panel__title${hovered ? ' tracks-panel__title--hovered' : ''}`}>{label}</span>
        <span className="tracks-panel__meta">
          {/* The date moves down here, ahead of distance/duration, once a name has taken its
              place as the title above — otherwise it's already the title and repeating it here
              would be redundant. Type trails the line. */}
          {displayName && `${formatStartedAt(track.startedAt, track.timezone)} · `}
          {/* A private track has no track, so no distance or duration — "0.0 mi · 0m" would
              read as broken data rather than as hidden on purpose. Its badge says why. */}
          {!track.private && (
            <>
              {formatDistance(track.distanceMeters, system)} · {formatDuration(track.movingSeconds)} ·{' '}
            </>
          )}
          {formatTrackType(track.trackType)}
        </span>
      </button>
      {(isPending || hidden || track.private || otherTrips.length > 0) && (
        // One right-aligned group, so the badges share one right edge whatever the text beside
        // them does; side by side, so every row is one height (index.css).
        <span className="tracks-panel__badges">
          {otherTrips.length > 0 && <TripBadge trips={otherTrips} inOpenTrip={openTripId !== undefined} onOpen={onOpenTrip} />}
          {isPending && (
            <span className="tracks-panel__hidden-badge" title={t('tracks.pending_title')}>
              {t('tracks.pending')}
            </span>
          )}
          {track.private && !isPending && (
            <span className="tracks-panel__hidden-badge tracks-panel__private-badge" title={t('tracks.private_title')}>
              <Lock size={10} aria-hidden="true" />
              {t('tracks.private')}
            </span>
          )}
          {hidden && <span className="tracks-panel__hidden-badge">{t('tracks.hidden')}</span>}
        </span>
      )}
      {remove && (
        <button
          type="button"
          className="tracks-panel__row-remove"
          disabled={remove.disabled}
          aria-label={`${remove.label}: ${label}`}
          title={remove.label}
          onClick={remove.onRemove}
        >
          <X size={14} />
        </button>
      )}
    </li>
  );
}

/**
 * A row's Trip badge (`SPEC.md` FR-5.1): the Trips this track is in — besides the open one,
 * on the Trips tab. A button that opens a Trip: with one, that Trip; with more, a small menu
 * of their names to pick from. Without `onOpen` it's a plain label.
 */
function TripBadge({
  trips,
  inOpenTrip,
  onOpen,
}: {
  trips: Track['trips'];
  inOpenTrip: boolean;
  onOpen: ((id: string) => void) | undefined;
}) {
  const [menuOpen, setMenuOpen] = useState(false);
  const ref = useRef<HTMLSpanElement>(null);

  useDismiss(ref, menuOpen, setMenuOpen);

  const label = tn('tracks.trip_badge', trips.length);
  const names = tn(inOpenTrip ? 'tracks.in_other_trips' : 'tracks.in_trips', trips.length, {
    names: trips.map((s) => s.name).join(', '),
  });
  if (!onOpen) {
    return (
      <span className="tracks-panel__hidden-badge tracks-panel__trip-badge" title={names}>
        {label}
      </span>
    );
  }
  const only = trips.length === 1 ? trips[0]! : null;
  const title = only ? t('tracks.open_trip', { name: only.name }) : names;
  return (
    <span className="tracks-panel__trip-badge-wrap" ref={ref}>
      <button
        type="button"
        className="tracks-panel__hidden-badge tracks-panel__trip-badge"
        aria-label={title}
        title={title}
        aria-haspopup={only ? undefined : 'menu'}
        aria-expanded={only ? undefined : menuOpen}
        onClick={() => {
          if (only) onOpen(only.id);
          else setMenuOpen((o) => !o);
        }}
      >
        {label}
      </button>
      {menuOpen && (
        <span className="trip-menu__panel tracks-panel__trip-badge-menu">
          {trips.map((trip) => (
            <button
              key={trip.id}
              type="button"
              className="trip-menu__item"
              onClick={() => {
                setMenuOpen(false);
                onOpen(trip.id);
              }}
            >
              <span className="trip-menu__name">{trip.name}</span>
            </button>
          ))}
        </span>
      )}
    </span>
  );
}
