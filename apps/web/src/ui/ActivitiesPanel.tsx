import { useCallback, useEffect, useRef, useState } from 'react';
import type { Map as MapLibreMap } from 'maplibre-gl';
import { ChevronDown, ChevronUp } from 'lucide-react';
import type { Activity, Story } from '../api';
import { ActivitiesToolbar } from './ActivitiesToolbar';
import { ActivityFilters, type DatesProps } from './ActivityFilters';
import { ActivityRow, useScrollFocusedRow } from './ActivityRow';
import { FirstRunPanel } from './FirstRunPanel';
import { AREA_LIMIT } from '../map/areaLoad';
import { PrivateLocationsPanel } from './PrivateLocationsPanel';
import { StoriesTab } from './StoriesTab';
import type { StoryInboxState } from './useStoryInbox';
import type { DistanceRange, TypeFacet } from './activityFacets';
import { formatTotalDistance } from './format';
import { useUnitSystem } from './units';
import { lang, t, tn } from '../i18n';

/**
 * The left sidebar, with three tabs, each about what the map shows under it: **Activities** (the
 * list, below), **Stories** (StoriesTab.tsx — every Story as a folder, the open one's
 * activities inside it, FR-14.6) and **Privacy** (PrivateLocationsPanel.tsx — FR-8.1's list,
 * whose editor floats over the map like Edit track's). Importing is the header's Upload menu and
 * the /sync page, not a tab here. The tab is MapView's state, so `/?private-locations` can open
 * onto Privacy, `/?story=` onto Stories, and the tab survives this panel unmounting for
 * Fog/Heatmap.
 *
 * The activity list — a permanent left sidebar, not paginated: every activity crossing the visible
 * map (FR-5.19), narrowed by the filter row (ActivityFilters.tsx: Type, Dates, Distance). MapView
 * owns the fetch, the area and the filters' state; this component is presentational plus its own
 * sheet and panel-resize state.
 *
 * The header toolbar (ActivitiesToolbar.tsx) sits directly above the row list. Every single-item
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
 *  - Hovering the row (anywhere on it) previews that activity's track — bold on the map,
 *    nothing else — for as long as the pointer stays there. Purely a preview: the camera
 *    never moves for it, and it clears the moment the pointer leaves.
 *  - Clicking the row's text *selects* it (the row-click focus) — bolds its track, highlights
 *    the row, flies there, and replaces whichever row was selected before. Clicking empty
 *    space in the list (or on the map) clears it. Never touches any checkbox.
 *  - The checkbox only *adds or removes* this one row from the checked group the toolbar acts
 *    on — no bold track, no row highlight, no fly. Never touches the selection.
 *  - The toolbar's Show/hide button toggles whether the target's tracks paint on the map at
 *    all, independent of all three of the above; a hidden activity's row dims in place.
 */
export interface ActivitiesPanelProps {
  /** A demo account (`docs/SPEC.md` FR-2.1–FR-2.3) — the
   *  backend already rejects every mutation a demo session attempts (requireNotDemo), so this
   *  disables the controls that would otherwise error, with a `title` explaining why, rather
   *  than either hiding them (which would hide the feature existing at all, undercutting the
   *  demo's whole point of letting someone feel the app) or leaving them enabled to fail.
   *  Group visible stays enabled either way — purely local UI state, never sent to the
   *  backend, so there's nothing for a demo account to be blocked from there. */
  readOnly?: boolean;
  /** Rows already narrowed by TYPE/DISTANCE — what actually renders. */
  activities: Activity[];
  loading: boolean;
  error: string | null;
  facets: TypeFacet[];
  excludedTypes: ReadonlySet<string>;
  onToggleType: (type: string) => void;
  distanceBounds: DistanceRange | null;
  distanceFilter: DistanceRange | null;
  onChangeDistance: (next: DistanceRange | null) => void;
  onResetFilters: () => void;
  /** The checkbox group — additive/subtractive, independent of `focusedId` below. */
  checked: Set<string>;
  /** What the header toolbar acts on — `checked` when it's non-empty, else `focusedId` alone,
   *  else nothing (MapView's toolbarTargetIds). */
  targetIds: Set<string>;
  /** The selected row (row-click focus) — at most one id, independent of `checked` above. */
  focusedId: string | null;
  /** The shared hover-preview id (MapView's `hoveredActivityId`) — fed by both this panel's
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
  onHoverActivity: (id: string | null) => void;
  /** Empties the checked group — the header checkbox's "uncheck all", and its menu's None. */
  onClear: () => void;
  /** Checks every currently-listed row — the header checkbox's "check all", and its menu's All. */
  onSelectAll: () => void;
  /** Checks every unchecked listed row and unchecks every checked one — the header checkbox's
   *  menu's Invert. */
  onInvertSelection: () => void;
  /** Flies to fit the toolbar's target without changing it. */
  onShowSelected: () => void;
  /** Activities currently hidden from the map — dims the row (there's no per-row eye icon any
   *  more), and what the header toolbar's "Group visible" button toggles in bulk over
   *  `targetIds`. */
  hiddenIds: Set<string>;
  /** The header toolbar's "Group visible": if any of the target is currently hidden, show all
   *  of it; otherwise hide all of it. See MapView's
   *  toggleGroupVisibility for the exact rule. */
  onToggleGroupVisibility: () => void;
  /** §4.7.5's toolbar Delete — the only delete entry point (over the toolbar's target: the
   *  checked group, or the selected row alone), so always an array even for one id. Unlike onActivityUpdated, this also has to drop every deleted id from
   *  `checked`/`hiddenIds`/`focusedId` and refresh the map's track layer and the first activity's day
   *  (deleting changes distance/duration, editing never does) — MapView's own
   *  handleActivitiesDeleted does more than a plain reload. */
  onActivitiesDeleted: (ids: string[]) => void;
  /** The toolbar's Edit button, over the toolbar's target — MapView opens the Edit window
   *  (EditActivityWindow.tsx: Activity and Track tabs) over the map. */
  onEdit: (activities: Activity[]) => void;
  /** A Story just made of the toolbar's target with Add to story's "New story…"
   *  (AddToStoryMenu.tsx) — MapView opens it on the Stories tab. */
  onStoryCreated: (story: Story) => void;
  /** An existing Story the toolbar's target was just added to with Add to story, as the server
   *  returned it — MapView reloads the list so the rows' Story badges follow. */
  onStoryAdded: (story: Story) => void;
  /** The Stories tab's list and its open Story — MapView's. */
  stories: StoriesPanel;
  tab: PanelTab;
  onTabChange: (tab: PanelTab) => void;
  /** Holds a phone's sheet open from outside: the tour's panel steps. */
  sheetOpen?: boolean;
  /** The Privacy tab's map, for its overlay — null until MapView's map has loaded. */
  map: MapLibreMap | null;
  /** A saved or deleted Private location — MapView's handlePrivateLocationsChanged. */
  onPrivateLocationsChanged: () => void;
  /** The Dates filter (FR-5.20): MapView's, with its bounds. */
  dates: DatesProps;
  /** How many the area holds when the list was cut at its limit (FR-5.19), else null. */
  cappedTotal: number | null;
  /** The account has no activities: the Activities tab is FirstRunPanel.tsx instead of the list
   *  (firstRun.ts's showsFirstRun). */
  firstRun?: boolean;
}

export type PanelTab = 'activities' | 'stories' | 'private';

/** What the Stories tab needs from MapView beyond the activity list the other tabs share —
 *  see StoriesTab.tsx's props of the same names. */
export interface StoriesPanel {
  stories: Story[];
  ready: boolean;
  error: string | null;
  inbox: StoryInboxState;
  openId: string | null;
  openStory: Story | null;
  openError: string | null;
  onOpen: (id: string) => void;
  onEdited: (story: Story) => void;
  onDeleted: (id: string) => void;
  onActivityRemoved: (story: Story, activityId: string) => void;
}

export function ActivitiesPanel({
  readOnly = false,
  activities,
  loading,
  error,
  facets,
  excludedTypes,
  onToggleType,
  distanceBounds,
  distanceFilter,
  onChangeDistance,
  onResetFilters,
  checked,
  targetIds,
  focusedId,
  hoveredId,
  onToggle,
  onFocus,
  onClearFocus,
  onHoverActivity,
  onClear,
  onSelectAll,
  onInvertSelection,
  onShowSelected,
  hiddenIds,
  onToggleGroupVisibility,
  onActivitiesDeleted,
  onEdit,
  onStoryCreated,
  onStoryAdded,
  stories,
  tab,
  onTabChange: setTab,
  sheetOpen = false,
  map,
  onPrivateLocationsChanged,
  dates,
  cappedTotal,
  firstRun = false,
}: ActivitiesPanelProps) {
  // The row list, for useScrollFocusedRow (ActivityRow.tsx): a newly focused row scrolls into view.
  const listRef = useRef<HTMLUListElement>(null);
  useScrollFocusedRow(listRef, focusedId);

  // The tab strip scrolls sideways when the tabs don't fit (index.css); the selected tab is
  // brought into view, scrolling the strip alone, for the reason useScrollFocusedRow gives.
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
  // default, same reasoning as typeFilterOpen above. Desktop CSS never reacts to the
  // `--sheet-expanded` modifier class this drives, so toggling it there is an inert no-op,
  // not a behavior change — safe to leave wired unconditionally rather than gated behind a JS
  // media-query check.
  const [sheetPicked, setSheetExpanded] = useState(false);
  const sheetExpanded = sheetPicked || sheetOpen;
  // An empty account's sheet opens onto the first-run panel, which the peek strip would hide,
  // and closes again when the first activity lands, so its track is in view.
  useEffect(() => setSheetExpanded(firstRun), [firstRun]);
  // A tab tap on a phone opens the sheet onto the tab just chosen: collapsed, the tab row is
  // all there is of it.
  const selectTab = (next: PanelTab) => {
    setTab(next);
    setSheetExpanded(true);
  };

  // Wider than the old fixed 320px, and now draggable — a full "Sep 11, 2026, 09:00 AM"
  // title plus its TYPE label was clipping at 320px. Local state, not lifted to MapView:
  // nothing outside this component's own layout needs to know the panel's width, the same
  // reasoning as `typeFilterOpen` above. Not persisted across reloads on purpose — no other UI
  // preference in this app is, and adding the one-off localStorage-plus-SSR-mismatch
  // handling for just this value isn't worth it before anything else here does the same.
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
  const targetActivities = activities.filter((a) => targetIds.has(a.id));
  const targetMeters = targetActivities.reduce((sum, a) => sum + (a.distanceMeters ?? 0), 0);

  return (
    <div
      className={`activities-panel${sheetExpanded ? ' activities-panel--sheet-expanded' : ''}`}
      data-testid="activities-panel"
      // A CSS custom property, not a direct `width`, specifically so the mobile media query
      // can override it with a plain `width: 100%` rule — an inline style always beats an
      // external stylesheet rule short of `!important` (which this codebase otherwise never
      // needs), but a custom property consumed by `width: var(--panel-width)` in the base
      // rule is just a normal declaration the media query's own later, equal-specificity
      // `width` rule can cleanly win over.
      style={{ '--panel-width': `${panelWidth}px` } as React.CSSProperties}
    >
      <div
        className="activities-panel__resize-handle"
        data-testid="activities-panel-resize"
        role="separator"
        aria-orientation="vertical"
        aria-label={t('activities.resize')}
        onPointerDown={onResizePointerDown}
        onPointerMove={onResizePointerMove}
        onPointerUp={onResizePointerUp}
        onPointerCancel={onResizePointerUp}
      />
      {/* On a phone the tab row is the collapsed sheet's peek strip, and the chevron at its end
          the sheet's expand/collapse control; index.css hides the chevron at desktop width. */}
      <div className="activities-panel__head">
        <div className="activities-panel__tabs" role="tablist" aria-label={t('activities.panel')} ref={tabsRef}>
          <button
            type="button"
            role="tab"
            aria-selected={tab === 'activities'}
            className="activities-panel__tab"
            data-testid="activities-panel-tab-activities"
            onClick={() => selectTab('activities')}
          >
            <span className="activities-panel__heading-text">{t('activities.tab')}</span>
            {/* On the Stories tab the list is the open Story's, not the area's. */}
            {tab !== 'stories' && <span className="activities-panel__badge">{activities.length.toLocaleString(lang)}</span>}
          </button>
          <button
            type="button"
            role="tab"
            aria-selected={tab === 'stories'}
            className="activities-panel__tab"
            data-testid="activities-panel-tab-stories"
            onClick={() => selectTab('stories')}
          >
            <span className="activities-panel__heading-text">{t('stories.tab')}</span>
            {/* Copies others sent, waiting to be accepted or declined (FR-14.7). */}
            {stories.inbox.sends.length > 0 && (
              <span
                className="activities-panel__badge activities-panel__badge--waiting"
                title={tn('stories.inbox_waiting', stories.inbox.sends.length)}
                aria-label={tn('stories.inbox_waiting', stories.inbox.sends.length)}
                data-testid="activities-panel-stories-waiting"
              >
                {stories.inbox.sends.length.toLocaleString(lang)}
              </span>
            )}
          </button>
          <button
            type="button"
            role="tab"
            aria-selected={tab === 'private'}
            className="activities-panel__tab"
            data-testid="activities-panel-tab-private"
            onClick={() => selectTab('private')}
          >
            <span className="activities-panel__heading-text">{t('private.tab')}</span>
          </button>
        </div>
        <button
          type="button"
          className="activities-panel__sheet-toggle"
          data-testid="activities-panel-sheet-toggle"
          aria-expanded={sheetExpanded}
          aria-label={t(sheetExpanded ? 'activities.collapse_sheet' : 'activities.expand_sheet')}
          onClick={() => setSheetExpanded((expanded) => !expanded)}
        >
          {sheetExpanded ? <ChevronDown size={20} /> : <ChevronUp size={20} />}
        </button>
      </div>
      {/* The Activities tab has no subtext: its filters say what's listed. */}
      {tab !== 'activities' && (
        <p className="activities-panel__subtext">{tab === 'private' ? t('private.subtitle') : t('stories.subtext')}</p>
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
          <p className="edit-track__note">{t('common.loading')}</p>
        )
      ) : tab === 'stories' ? (
        <StoriesTab
          readOnly={readOnly}
          stories={stories.stories}
          storiesReady={stories.ready}
          storiesError={stories.error}
          inbox={stories.inbox}
          openId={stories.openId}
          openStory={stories.openStory}
          openError={stories.openError}
          activities={activities}
          activitiesLoading={loading}
          activitiesError={error}
          focusedId={focusedId}
          hoveredId={hoveredId}
          onOpen={(id) => {
            // On a phone the expanded sheet would cover the Story's tracks, as after View on map.
            setSheetExpanded(false);
            stories.onOpen(id);
          }}
          onFocus={onFocus}
          onClearFocus={onClearFocus}
          onHoverActivity={onHoverActivity}
          onEdited={stories.onEdited}
          onDeleted={stories.onDeleted}
          onActivityRemoved={stories.onActivityRemoved}
        />
      ) : firstRun ? (
        <FirstRunPanel inbox={stories.inbox} onPrivacy={() => selectTab('private')} />
      ) : (
        <>
          <ActivityFilters
            facets={facets}
            excludedTypes={excludedTypes}
            onToggleType={onToggleType}
            distanceBounds={distanceBounds}
            distanceFilter={distanceFilter}
            onChangeDistance={onChangeDistance}
            onResetFilters={onResetFilters}
            dates={dates}
          />

          <ActivitiesToolbar
            readOnly={readOnly}
            activities={activities}
            checked={checked}
            targetIds={targetIds}
            hiddenIds={hiddenIds}
            onClear={onClear}
            onSelectAll={onSelectAll}
            onInvertSelection={onInvertSelection}
            onToggleGroupVisibility={onToggleGroupVisibility}
            onEdit={onEdit}
            onStoryCreated={onStoryCreated}
            onStoryAdded={onStoryAdded}
            onActivitiesDeleted={onActivitiesDeleted}
            onShowSelected={onShowSelected}
          />
          {cappedTotal !== null && (
            <p className="activities-panel__capped" data-testid="activities-capped">
              {t('activities.newest_of', { shown: AREA_LIMIT.toLocaleString(lang), total: cappedTotal.toLocaleString(lang) })}
            </p>
          )}

          {/* A click on the list's own empty space (or one of its notes) — not on a row —
              clears the selection, the panel's counterpart to clicking away from every track
              on the map. Rows are <li>s filling the list's width, so a click on one never
              reaches here as the target. */}
          <ul
            className="activities-panel__list"
            data-testid="activities-list"
            ref={listRef}
            onClick={(e) => {
              const target = e.target as HTMLElement;
              if (target === e.currentTarget || target.classList.contains('activities-panel__note')) onClearFocus();
            }}
          >
            {activities.map((activity) => (
              <ActivityRow
                key={activity.id}
                activity={activity}
                system={system}
                focused={focusedId === activity.id}
                hovered={hoveredId === activity.id}
                hidden={hiddenIds.has(activity.id)}
                checkbox={{ checked: checked.has(activity.id), onToggle: () => onToggle(activity.id) }}
                onOpenStory={(id) => {
                  // On a phone the expanded sheet would cover the Story's tracks, as on the Stories tab.
                  setSheetExpanded(false);
                  stories.onOpen(id);
                }}
                onFocus={() => onFocus(activity.id)}
                onHover={onHoverActivity}
              />
            ))}
            {loading && <li className="activities-panel__note">{t('common.loading')}</li>}
            {error && !loading && (
              <li className="activities-panel__note activities-panel__note--error">{error}</li>
            )}
            {!loading && !error && activities.length === 0 && (
              <li className="activities-panel__note">{t('activities.none_match')}</li>
            )}
          </ul>

          {/* Just the summary now — the fly-to-fit action it used to hold moved to the toolbar's
              own accent-tinted "Focus checked group on the map" icon above. */}
          <div className="activities-panel__footer">
            <span className="activities-panel__footer-summary">
              {t('activities.footer', { n: targetActivities.length, distance: formatTotalDistance(targetMeters, system) })}
            </span>
          </div>

        </>
      )}



    </div>
  );
}
