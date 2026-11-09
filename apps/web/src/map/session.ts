/**
 * The map's cross-feature state and the rules between its parts, as a reducer: which activities
 * the list and the tracks show (the area and the Dates filter, or a Story), the selection over
 * them, the mode, and whether the camera moves onto what's shown next. Features read it and change
 * it only through events; side effects (flights, the URL) stay with them. Android's
 * `map/MapSession.kt` keeps the date range the web replaced (docs/SPEC.md FR-6); the cases both
 * share are `testdata/client-rules`'s `panelState`, the web's own `webSession`.
 */
import type { BBox } from '../api';
import type { DistanceRange } from '../ui/activityFacets';
import { ALL_TIME, type DateFilter } from '../ui/dateFilter.ts';
import type { MapMode } from './mapMode';
import { toggled, toggledVisibility, toolbarTarget, withoutIds } from './selection.ts';

export interface Selection {
  /** The checkbox group the toolbar acts on. */
  checked: Set<string>;
  /** The one activity a row's text or its track focused: bolded and flown to. */
  focused: string | null;
  /** Tracks hidden from the map. */
  hidden: Set<string>;
  excludedTypes: Set<string>;
  distanceFilter: DistanceRange | null;
}

export interface MapSession {
  /** The Dates filter (FR-5.20); all time until set. */
  dates: DateFilter;
  /** The map view the list was last asked about (FR-5.19); null until the opening view settles. */
  area: BBox | null;
  /** The open Story: the list and tracks are its activities, [dates] and [area] kept for when it closes. */
  storyId: string | null;
  /** The camera moves onto what's shown next: a Story's list, or what Dates matches. */
  flyRequest: boolean;
  selection: Selection;
  mode: MapMode;
  /** The checked group and focus as Normal mode left them, restored on the way back. */
  modeSnapshot: { checked: Set<string>; focused: string | null } | null;
}

export type MapSessionEvent =
  /** Dates changed (dateFilter.ts's setDateFilter). The selection stays, as on any reload; the
   *  list then drops what left it (`listLoaded`). [fly] moves the camera onto the matches once. */
  | { type: 'datesSet'; dates: DateFilter; fly: boolean }
  /** The list is asked about this view: a move from zoom 10, the button, or a flight's end. */
  | { type: 'areaLoaded'; area: BBox }
  /** "View on map" for an activity not listed: Dates on its own day, and the camera onto it. */
  | { type: 'dayViewed'; day: string }
  | { type: 'storyEntered'; id: string }
  | { type: 'storyExited' }
  /** The camera has moved for the requested list. */
  | { type: 'flyConsumed' }
  | { type: 'modeChanged'; mode: MapMode }
  | { type: 'checkToggled'; id: string }
  | { type: 'checkedSet'; ids: Iterable<string> }
  | { type: 'focused'; id: string | null }
  /** The toolbar's Show/Hide over its target. */
  | { type: 'visibilityToggled' }
  | { type: 'typeToggled'; activityType: string }
  | { type: 'distanceSet'; filter: DistanceRange | null }
  | { type: 'filtersReset' }
  /** A list was read for the area or Story shown: a row it no longer has leaves the selection. */
  | { type: 'listLoaded'; ids: Iterable<string> }
  /** Activities left the account (deleted, or taken out of the open Story): their ids leave the selection. */
  | { type: 'activitiesRemoved'; ids: Iterable<string>; unfocusOnly?: boolean };

export function emptySelection(): Selection {
  return { checked: new Set(), focused: null, hidden: new Set(), excludedTypes: new Set(), distanceFilter: null };
}

export function initialSession(storyId: string | null): MapSession {
  return { dates: ALL_TIME, area: null, storyId, flyRequest: false, selection: emptySelection(), mode: 'normal', modeSnapshot: null };
}

/** Two boxes the same to about a metre: a view the list was already asked about. */
function sameArea(a: BBox | null, b: BBox): boolean {
  return a !== null && a.every((v, i) => Math.abs(v - (b[i] ?? NaN)) < 1e-5);
}

export function mapSessionReducer(state: MapSession, event: MapSessionEvent): MapSession {
  const select = (selection: Partial<Selection>): MapSession => ({ ...state, selection: { ...state.selection, ...selection } });
  switch (event.type) {
    case 'datesSet':
      return { ...state, dates: event.dates, flyRequest: event.fly && state.storyId === null };
    case 'areaLoaded':
      return sameArea(state.area, event.area) ? state : { ...state, area: event.area };
    case 'dayViewed':
      return mapSessionReducer(state, { type: 'datesSet', dates: { after: event.day, before: event.day }, fly: true });
    case 'storyEntered':
      return { ...state, storyId: event.id, flyRequest: true, selection: emptySelection() };
    case 'storyExited':
      // The list returns to the area and Dates; the camera stays.
      return { ...state, storyId: null, flyRequest: false, selection: emptySelection() };
    case 'flyConsumed':
      return state.flyRequest ? { ...state, flyRequest: false } : state;
    case 'modeChanged': {
      if (event.mode === state.mode) return state;
      // Fog and Heatmap can't select or focus: leaving Normal keeps the group and focus aside,
      // and returning restores them. Fog to Heatmap touches neither.
      if (state.mode === 'normal') {
        const { checked, focused } = state.selection;
        return { ...state, mode: event.mode, modeSnapshot: { checked, focused }, selection: { ...state.selection, checked: new Set(), focused: null } };
      }
      if (event.mode === 'normal' && state.modeSnapshot) {
        const { checked, focused } = state.modeSnapshot;
        return { ...state, mode: event.mode, modeSnapshot: null, selection: { ...state.selection, checked, focused } };
      }
      return { ...state, mode: event.mode, modeSnapshot: event.mode === 'normal' ? null : state.modeSnapshot };
    }
    case 'checkToggled':
      return select({ checked: toggled(state.selection.checked, event.id) });
    case 'checkedSet':
      return select({ checked: new Set(event.ids) });
    case 'focused':
      return state.selection.focused === event.id ? state : select({ focused: event.id });
    case 'visibilityToggled':
      return select({ hidden: toggledVisibility(state.selection.hidden, toolbarTarget(state.selection.checked, state.selection.focused)) });
    case 'typeToggled':
      return select({ excludedTypes: toggled(state.selection.excludedTypes, event.activityType) });
    case 'distanceSet':
      return state.selection.distanceFilter === event.filter ? state : select({ distanceFilter: event.filter });
    case 'filtersReset':
      return select({ excludedTypes: new Set(), distanceFilter: null });
    case 'listLoaded': {
      const kept = new Set(event.ids);
      const { checked, focused, hidden } = state.selection;
      const gone = new Set([...checked, ...hidden, ...(focused !== null ? [focused] : [])].filter((id) => !kept.has(id)));
      return gone.size === 0 ? state : mapSessionReducer(state, { type: 'activitiesRemoved', ids: gone });
    }
    case 'activitiesRemoved': {
      const ids = new Set(event.ids);
      const { checked, focused, hidden } = state.selection;
      const nextFocused = focused !== null && ids.has(focused) ? null : focused;
      if (event.unfocusOnly) return nextFocused === focused ? state : select({ focused: nextFocused });
      const nextChecked = withoutIds(checked, ids);
      const nextHidden = withoutIds(hidden, ids);
      if (nextFocused === focused && nextChecked === checked && nextHidden === hidden) return state;
      return select({ focused: nextFocused, checked: nextChecked as Set<string>, hidden: nextHidden as Set<string> });
    }
  }
}
