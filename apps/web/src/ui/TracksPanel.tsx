import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { Map as MapLibreMap } from 'maplibre-gl';
import { ChevronDown, ChevronUp } from 'lucide-react';
import type { Track, Trip } from '../api.ts';
import { TracksToolbar } from './TracksToolbar.tsx';
import { TrackFilters, type DatesProps } from './TrackFilters.tsx';
import { TrackRow, rowLabel } from './TrackRow.tsx';
import { targetSummaryKind } from '../map/selection.ts';
import { useListWindow } from './useListWindow.ts';
import { FirstRunPanel } from './FirstRunPanel.tsx';
import { PrivateLocationsPanel } from './PrivateLocationsPanel.tsx';
import { TripsTab } from './TripsTab.tsx';
import type { TripInboxState } from './useTripInbox.ts';
import { emptyListReason, type DistanceRange, type TypeFacet } from './trackFacets.ts';
import { formatTotalDistance } from './format.ts';
import { useUnitSystem } from './units.ts';
import { lang, t, tn } from '../i18n/index.ts';
import { onTabListKeyDown } from './tabKeys.ts';

/**
 * The left sidebar, with three tabs, each about what the map shows under it: **Tracks** (the
 * list, below), **Trips** (TripsTab.tsx — every Trip as a folder, the open one's
 * tracks inside it, FR-13.6) and **Privacy** (PrivateLocationsPanel.tsx — FR-7.1's list,
 * whose editor floats over the map like Edit route's). Importing is the header's Upload menu and
 * the /sync page, not a tab here. The tab is MapView's state, so `/?private-locations` can open
 * onto Privacy, `/?trip=` onto Trips, and the tab survives this panel unmounting for Fog.
 *
 * The track list — a permanent left sidebar, not paginated: every track crossing the visible
 * map (FR-5.11), narrowed by the filter row (TrackFilters.tsx: Type, Dates, Distance). MapView
 * owns the fetch, the area and the filters' state; this component is presentational plus its own
 * sheet and panel-resize state.
 *
 * The header toolbar (TracksToolbar.tsx) sits directly above the row list. Every single-item
 * action lives there, not on the row — a row has only its checkbox and its text. The toolbar acts
 * on its *target* (MapView's toolbarTargetIds): the checked group whenever anything is checked,
 * else the selected row alone, never the two together: a group is built one tick at a time while
 * a row is focused just by looking at it, so a union would sweep the last-clicked row into a
 * Delete. The footer keeps only the target's "N checked · X km" summary.
 *
 * Four interactions per row, all living in MapView (which holds the map instance they need;
 * this component owns only rendering and its own local UI state). Selection and the checkbox
 * group are two fully independent mechanisms — reported live as wrongly coupled once, when a
 * row click also silently checked/unchecked boxes:
 *  - Hovering the row (anywhere on it) previews that track's track — bold on the map,
 *    nothing else — for as long as the pointer stays there. Purely a preview: the camera
 *    never moves for it, and it clears the moment the pointer leaves.
 *  - Clicking the row's text *selects* it (the row-click focus) — bolds its track, highlights
 *    the row, flies there, and replaces whichever row was selected before. Clicking empty
 *    space in the list (or on the map) clears it. Never touches any checkbox.
 *  - The checkbox only *adds or removes* this one row from the checked group the toolbar acts
 *    on — no bold track, no row highlight, no fly. Never touches the selection.
 *  - The toolbar's Show/hide button toggles whether the target's tracks paint on the map at
 *    all, independent of all three of the above; a hidden track's row dims in place.
 */
interface TracksPanelProps {
  /** A demo account (`docs/SPEC.md` FR-2.1–FR-2.3) — the
   *  backend already rejects every mutation a demo session attempts (requireNotDemo), so this
   *  disables the controls that would otherwise error, with a `title` explaining why, rather
   *  than either hiding them (which would hide the feature existing at all, undercutting the
   *  demo's whole point of letting someone feel the app) or leaving them enabled to fail.
   *  Group visible stays enabled either way — purely local UI state, never sent to the
   *  backend, so there's nothing for a demo account to be blocked from there. */
  readOnly?: boolean;
  /** Rows already narrowed by TYPE/DISTANCE — what actually renders. */
  tracks: Track[];
  loading: boolean;
  error: string | null;
  facets: TypeFacet[];
  excludedTypes: ReadonlySet<string>;
  onToggleType: (type: string) => void;
  distanceBounds: DistanceRange | null;
  distanceFilter: DistanceRange | null;
  onChangeDistance: (next: DistanceRange | null) => void;
  /** The checkbox group — additive/subtractive, independent of `focusedId` below. */
  checked: Set<string>;
  /** What the header toolbar acts on — `checked` when it's non-empty, else `focusedId` alone,
   *  else nothing (MapView's toolbarTargetIds). */
  targetIds: Set<string>;
  /** The selected row (row-click focus) — at most one id, independent of `checked` above. */
  focusedId: string | null;
  /** The shared hover-preview id (MapView's `hoveredTrackId`) — fed by both this panel's
   *  own row `onMouseEnter`/`onMouseLeave` below *and* the map's own track hover
   *  (`tracks.ts`'s `onHover`), so hovering a track on the map underlines the matching row's
   *  title here, the same way hovering a row already bolds its track on the map. */
  hoveredId: string | null;
  /** The checkbox: adds/removes this one row from `checked`. */
  onToggle: (id: string) => void;
  /** The row's text: replaces `focusedId` with this one row. */
  onFocus: (id: string) => void;
  /** A click on empty space in the list: clears `focusedId`, leaving `checked` alone. */
  onClearFocus: () => void;
  /** The row's own hover preview, `null` on leave — see the component doc comment above. */
  onHoverTrack: (id: string | null) => void;
  /** Empties the checked group — the header checkbox's "uncheck all", and its menu's None. */
  onClear: () => void;
  /** Checks every currently-listed row — the header checkbox's "check all", and its menu's All. */
  onSelectAll: () => void;
  /** Checks every unchecked listed row and unchecks every checked one — the header checkbox's
   *  menu's Invert. */
  onInvertSelection: () => void;
  /** Flies to fit the toolbar's target without changing it. */
  onShowSelected: () => void;
  /** The toolbar's Info (TracksToolbar.tsx). */
  onInfo: () => void;
  /** Tracks currently hidden from the map — dims the row (there's no per-row eye icon any
   *  more), and what the header toolbar's "Group visible" button toggles in bulk over
   *  `targetIds`. */
  hiddenIds: Set<string>;
  /** The header toolbar's "Group visible": if any of the target is currently hidden, show all
   *  of it; otherwise hide all of it. See MapView's
   *  toggleGroupVisibility for the exact rule. */
  onToggleGroupVisibility: () => void;
  /** §4.7.5's toolbar Delete — the only delete entry point (over the toolbar's target: the
   *  checked group, or the selected row alone), so always an array even for one id. Unlike an edit, this also has to drop every deleted id from
   *  `checked`/`hiddenIds`/`focusedId` and refresh the map's track layer and the first track's day
   *  (deleting changes distance/duration, editing never does) — MapView's own
   *  handleTracksDeleted does more than a plain reload. */
  onTracksDeleted: (ids: string[]) => void;
  /** The toolbar's Edit button, over the toolbar's target — MapView opens the Edit window
   *  (EditTrackWindow.tsx: Track and Route tabs) over the map. */
  onEdit: (tracks: Track[]) => void;
  /** A Trip just made of the toolbar's target with Add to trip's "New trip…"
   *  (AddToTripMenu.tsx) — MapView opens it on the Trips tab. */
  onTripCreated: (trip: Trip) => void;
  /** An existing Trip the toolbar's target was just added to with Add to trip, as the server
   *  returned it — MapView reloads the list so the rows' Trip badges follow. */
  onTripAdded: (trip: Trip) => void;
  /** The Trips tab's list and its open Trip — MapView's. */
  trips: TripsPanel;
  tab: PanelTab;
  onTabChange: (tab: PanelTab) => void;
  /** Holds a phone's sheet open from outside: the tour's panel steps. */
  sheetOpen?: boolean;
  /** The Privacy tab's map, for its overlay — null until MapView's map has loaded. */
  map: MapLibreMap | null;
  /** A saved or deleted Private location — MapView's handlePrivateLocationsChanged. */
  onPrivateLocationsChanged: () => void;
  /** The Dates filter (FR-5.12): MapView's, with its bounds. */
  dates: DatesProps;
  /** The map is zoomed out past where tracks are drawn, so there's nothing to list (FR-5.11). */
  outOfReach: boolean;
  /** The account has no tracks: the Tracks tab is FirstRunPanel.tsx instead of the list
   *  (firstRun.ts's showsFirstRun). */
  firstRun?: boolean;
}

export type PanelTab = 'tracks' | 'trips' | 'private';

/** How long a list load runs before the progress bar shows. */
const PROGRESS_DELAY_MS = 300;

/** What the Trips tab needs from MapView beyond the track list the other tabs share —
 *  see TripsTab.tsx's props of the same names. */
export interface TripsPanel {
  trips: Trip[];
  ready: boolean;
  error: string | null;
  inbox: TripInboxState;
  openId: string | null;
  openTrip: Trip | null;
  openError: string | null;
  onOpen: (id: string) => void;
  onEdited: (trip: Trip) => void;
  onDeleted: (id: string) => void;
  onTrackRemoved: (trip: Trip, trackId: string) => void;
}

export function TracksPanel({
  readOnly = false,
  tracks,
  loading,
  error,
  facets,
  excludedTypes,
  onToggleType,
  distanceBounds,
  distanceFilter,
  onChangeDistance,
  checked,
  targetIds,
  focusedId,
  hoveredId,
  onToggle,
  onFocus,
  onClearFocus,
  onHoverTrack,
  onClear,
  onSelectAll,
  onInvertSelection,
  onShowSelected,
  onInfo,
  hiddenIds,
  onToggleGroupVisibility,
  onTracksDeleted,
  onEdit,
  onTripCreated,
  onTripAdded,
  trips,
  tab,
  onTabChange: setTab,
  sheetOpen = false,
  map,
  onPrivateLocationsChanged,
  dates,
  outOfReach,
  firstRun = false,
}: TracksPanelProps) {
  // The row list renders only the rows in view (useListWindow.ts): up to 1,000 again on every
  // reload of the area stalled the page. All rows are one line high, measured from the first drawn.
  const listRef = useRef<HTMLUListElement>(null);
  const shownCount = outOfReach ? 0 : tracks.length;
  const focusedIndex = useMemo(() => (focusedId === null ? -1 : tracks.findIndex((a) => a.id === focusedId)), [tracks, focusedId]);
  const { start, end, rowHeight } = useListWindow(listRef, listRef, shownCount, { id: focusedId, index: focusedIndex });
  // A reload of the area keeps the old rows until the new ones land; the bar over the list says
  // one is under way, only once it has taken long enough to notice, so a quick pan doesn't flicker.
  const [slowLoad, setSlowLoad] = useState(false);
  useEffect(() => {
    if (!loading) {
      setSlowLoad(false);
      return;
    }
    const timer = setTimeout(() => setSlowLoad(true), PROGRESS_DELAY_MS);
    return () => clearTimeout(timer);
  }, [loading]);

  // The tab strip scrolls sideways when the tabs don't fit (index.css); the selected tab is
  // brought into view, scrolling the strip alone: on a phone the collapsed sheet is an ancestor,
  // and `scrollIntoView` scrolling it pushed its header out of reach.
  const tabsRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const strip = tabsRef.current;
    const selected = strip?.querySelector<HTMLElement>('[aria-selected="true"]');
    if (!strip || !selected) return;
    const left = selected.getBoundingClientRect().left - strip.getBoundingClientRect().left + strip.scrollLeft;
    if (left < strip.scrollLeft || left + selected.offsetWidth > strip.scrollLeft + strip.clientWidth) {
      strip.scrollTo({ left: left - (strip.clientWidth - selected.offsetWidth) / 2, behavior: 'smooth' });
    }
  }, [tab]);



  // Mobile-only bottom sheet (index.css's `@media (max-width: 768px)` layer) — collapsed by
  // default. Desktop CSS never reacts to the `--sheet-expanded` modifier class this drives, so toggling it there is an inert no-op,
  // not a behavior change — safe to leave wired unconditionally rather than gated behind a JS
  // media-query check.
  const [sheetPicked, setSheetExpanded] = useState(false);
  const sheetExpanded = sheetPicked || sheetOpen;
  // An empty account's sheet opens onto the first-run panel, which the peek strip would hide,
  // and closes again when the first track lands, so its track is in view.
  useEffect(() => setSheetExpanded(firstRun), [firstRun]);
  // A tab tap on a phone opens the sheet onto the tab just chosen: collapsed, the tab row is
  // all there is of it.
  const selectTab = (next: PanelTab) => {
    setTab(next);
    setSheetExpanded(true);
  };

  // Draggable, and 380 px to start: a full "Sep 11, 2026, 09:00 AM" title with its type needs
  // more than 320. Local state, not lifted to MapView: nothing outside this component's own
  // layout needs the panel's width. Not kept across reloads, as no other UI preference here is.
  const [panelWidth, setPanelWidth] = useState(380);
  const resizeRef = useRef<{ pointerId: number; startX: number; startWidth: number } | null>(null);
  const MIN_PANEL_WIDTH = 260;
  const MAX_PANEL_WIDTH = 560;

  const onResizePointerDown = useCallback(
    (event: React.PointerEvent<HTMLDivElement>) => {
      event.currentTarget.setPointerCapture(event.pointerId);
      resizeRef.current = { pointerId: event.pointerId, startX: event.clientX, startWidth: panelWidth };
    },
    [panelWidth],
  );
  const onResizePointerMove = useCallback((event: React.PointerEvent<HTMLDivElement>) => {
    const drag = resizeRef.current;
    if (!drag || event.pointerId !== drag.pointerId) return;
    const next = drag.startWidth + (event.clientX - drag.startX);
    setPanelWidth(Math.min(Math.max(next, MIN_PANEL_WIDTH), MAX_PANEL_WIDTH));
  }, []);
  const onResizePointerUp = useCallback((event: React.PointerEvent<HTMLDivElement>) => {
    if (resizeRef.current?.pointerId === event.pointerId) resizeRef.current = null;
  }, []);

  const system = useUnitSystem();
  // The footer describes the toolbar's target, so it always matches what the toolbar would act on.
  const targetTracks = tracks.filter((a) => targetIds.has(a.id));
  const targetMeters = targetTracks.reduce((sum, a) => sum + (a.distanceMeters ?? 0), 0);

  return (
    <div
      className={`tracks-panel${sheetExpanded ? ' tracks-panel--sheet-expanded' : ''}`}
      data-testid="tracks-panel"
      // A CSS custom property, not a direct `width`, specifically so the mobile media query
      // can override it with a plain `width: 100%` rule — an inline style always beats an
      // external stylesheet rule short of `!important` (which this codebase otherwise never
      // needs), but a custom property consumed by `width: var(--panel-width)` in the base
      // rule is just a normal declaration the media query's own later, equal-specificity
      // `width` rule can cleanly win over.
      style={{ '--panel-width': `${panelWidth}px` } as React.CSSProperties}
    >
      <div
        className="tracks-panel__resize-handle"
        data-testid="tracks-panel-resize"
        // A pointer's affordance only: no keyboard can drag it, so it isn't announced as a control.
        aria-hidden="true"
        onPointerDown={onResizePointerDown}
        onPointerMove={onResizePointerMove}
        onPointerUp={onResizePointerUp}
        onPointerCancel={onResizePointerUp}
      />
      {/* On a phone the tab row is the collapsed sheet's peek strip, and the chevron at its end
          the sheet's expand/collapse control; index.css hides the chevron at desktop width. */}
      <div className="tracks-panel__head">
        <div className="tracks-panel__tabs" role="tablist" aria-label={t('tracks.panel')} ref={tabsRef}>
          <button
            type="button"
            role="tab"
            onKeyDown={onTabListKeyDown}
            aria-selected={tab === 'tracks'}
            tabIndex={tab === 'tracks' ? 0 : -1}
            className="tracks-panel__tab"
            data-testid="tracks-panel-tab-tracks"
            onClick={() => selectTab('tracks')}
          >
            <span className="tracks-panel__heading-text">{t('tracks.tab')}</span>
            {/* On the Trips tab the list is the open Trip's, not the area's. */}
            {tab !== 'trips' && <span className="tracks-panel__badge">{tracks.length.toLocaleString(lang)}</span>}
          </button>
          <button
            type="button"
            role="tab"
            onKeyDown={onTabListKeyDown}
            aria-selected={tab === 'trips'}
            tabIndex={tab === 'trips' ? 0 : -1}
            className="tracks-panel__tab"
            data-testid="tracks-panel-tab-trips"
            onClick={() => selectTab('trips')}
          >
            <span className="tracks-panel__heading-text">{t('trips.tab')}</span>
            {/* Copies others sent, waiting to be accepted or declined (FR-13.7). */}
            {trips.inbox.sends.length > 0 && (
              <span
                className="tracks-panel__badge tracks-panel__badge--waiting"
                title={tn('trips.inbox_waiting', trips.inbox.sends.length)}
                aria-label={tn('trips.inbox_waiting', trips.inbox.sends.length)}
                data-testid="tracks-panel-trips-waiting"
              >
                {trips.inbox.sends.length.toLocaleString(lang)}
              </span>
            )}
          </button>
          <button
            type="button"
            role="tab"
            onKeyDown={onTabListKeyDown}
            aria-selected={tab === 'private'}
            tabIndex={tab === 'private' ? 0 : -1}
            className="tracks-panel__tab"
            data-testid="tracks-panel-tab-private"
            onClick={() => selectTab('private')}
          >
            <span className="tracks-panel__heading-text">{t('private.tab')}</span>
          </button>
        </div>
        <button
          type="button"
          className="tracks-panel__sheet-toggle"
          data-testid="tracks-panel-sheet-toggle"
          aria-expanded={sheetExpanded}
          aria-label={t(sheetExpanded ? 'tracks.collapse_sheet' : 'tracks.expand_sheet')}
          onClick={() => setSheetExpanded((expanded) => !expanded)}
        >
          {sheetExpanded ? <ChevronDown size={20} /> : <ChevronUp size={20} />}
        </button>
      </div>
      {/* The Tracks tab has no subtext: its filters say what's listed. */}
      {tab !== 'tracks' && (
        <p className="tracks-panel__subtext">{tab === 'private' ? t('private.subtitle') : t('trips.subtext')}</p>
      )}

      {tab === 'private' ? (
        map ? (
          <PrivateLocationsPanel
            map={map}
            readOnly={readOnly}
            onChanged={onPrivateLocationsChanged}
            // On a phone the expanded sheet would cover the editor window and the circle it edits.
            // No visible effect at desktop width.
            onEditorOpen={() => setSheetExpanded(false)}
          />
        ) : (
          <p className="edit-route__note">{t('common.loading')}</p>
        )
      ) : tab === 'trips' ? (
        <TripsTab
          readOnly={readOnly}
          trips={trips.trips}
          tripsReady={trips.ready}
          tripsError={trips.error}
          inbox={trips.inbox}
          openId={trips.openId}
          openTrip={trips.openTrip}
          openError={trips.openError}
          tracks={tracks}
          tracksLoading={loading}
          tracksError={error}
          focusedId={focusedId}
          hoveredId={hoveredId}
          onOpen={(id) => {
            // On a phone the expanded sheet would cover the Trip's tracks, as after View on map.
            setSheetExpanded(false);
            trips.onOpen(id);
          }}
          onFocus={onFocus}
          onClearFocus={onClearFocus}
          onHoverTrack={onHoverTrack}
          onEdited={trips.onEdited}
          onDeleted={trips.onDeleted}
          onTrackRemoved={trips.onTrackRemoved}
        />
      ) : firstRun ? (
        <FirstRunPanel inbox={trips.inbox} onPrivacy={() => selectTab('private')} />
      ) : (
        <>
          <TrackFilters
            facets={facets}
            excludedTypes={excludedTypes}
            onToggleType={onToggleType}
            distanceBounds={distanceBounds}
            distanceFilter={distanceFilter}
            onChangeDistance={onChangeDistance}
            dates={dates}
          />

          <TracksToolbar
            readOnly={readOnly}
            tracks={tracks}
            checked={checked}
            targetIds={targetIds}
            hiddenIds={hiddenIds}
            onClear={onClear}
            onSelectAll={onSelectAll}
            onInvertSelection={onInvertSelection}
            onToggleGroupVisibility={onToggleGroupVisibility}
            onEdit={onEdit}
            onTripCreated={onTripCreated}
            onTripAdded={onTripAdded}
            onTracksDeleted={onTracksDeleted}
            onShowSelected={onShowSelected}
            onInfo={onInfo}
          />

          {/* A click on the list's own empty space (or one of its notes) — not on a row —
              clears the selection, the panel's counterpart to clicking away from every track
              on the map. Rows are <li>s filling the list's width, so a click on one never
              reaches here as the target. */}
          <div className={slowLoad && !outOfReach ? 'tracks-panel__progress tracks-panel__progress--on' : 'tracks-panel__progress'} role="progressbar" aria-label={t('common.loading')} aria-hidden={!slowLoad || outOfReach} data-testid="tracks-progress" />
          <ul
            className="tracks-panel__list"
            data-testid="tracks-list"
            ref={listRef}
            onClick={(e) => {
              const target = e.target as HTMLElement;
              if (target === e.currentTarget || target.classList.contains('tracks-panel__note') || target.classList.contains('tracks-panel__spacer')) onClearFocus();
            }}
          >
            {start > 0 && <li className="tracks-panel__spacer" style={{ height: start * rowHeight }} aria-hidden="true" />}
            {!outOfReach && tracks.slice(start, end).map((track) => (
              <TrackRow
                key={track.id}
                track={track}
                system={system}
                focused={focusedId === track.id}
                hovered={hoveredId === track.id}
                hidden={hiddenIds.has(track.id)}
                checkbox={{ checked: checked.has(track.id), onToggle: () => onToggle(track.id) }}
                onOpenTrip={(id) => {
                  // On a phone the expanded sheet would cover the Trip's tracks, as on the Trips tab.
                  setSheetExpanded(false);
                  trips.onOpen(id);
                }}
                onFocus={() => onFocus(track.id)}
                onHover={onHoverTrack}
              />
            ))}
            {!outOfReach && end < tracks.length && (
              <li className="tracks-panel__spacer" style={{ height: (tracks.length - end) * rowHeight }} aria-hidden="true" />
            )}
            {loading && !outOfReach && tracks.length === 0 && <li className="tracks-panel__note">{t('common.loading')}</li>}
            {error && !loading && (
              <li className="tracks-panel__note tracks-panel__note--error">{error}</li>
            )}
            {outOfReach ? (
              <li className="tracks-panel__note">{t('area.zoom_in')}</li>
            ) : (
              !loading &&
              !error &&
              tracks.length === 0 && (
                <li className="tracks-panel__note">
                  {t(emptyListReason(excludedTypes, distanceFilter, dates.value) === 'filters' ? 'tracks.none_match' : 'tracks.none_here')}
                </li>
              )
            )}
          </ul>

          {/* The toolbar's target and its distance: the Checked group, else the Focused row, named
              as FR-5.8 has it, so a row that's only focused never reads as checked. */}
          <div className="tracks-panel__footer">
            <span className="tracks-panel__footer-summary">
              {targetSummaryKind(checked.size, targetTracks.length) === 'focused' && targetTracks[0]
                ? t('tracks.footer_focused', { label: rowLabel(targetTracks[0]), distance: formatTotalDistance(targetMeters, system) })
                : t('tracks.footer', { n: targetTracks.length, distance: formatTotalDistance(targetMeters, system) })}
            </span>
          </div>

        </>
      )}



    </div>
  );
}
