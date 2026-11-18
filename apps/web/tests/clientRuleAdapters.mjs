// Each shared rule (testdata/client-rules/README.md) as a function of a case's input, for the
// suite and for scripts/generate-rule-cases.mjs. Plain .mjs so tsc leaves it alone; Node strips
// the types from the imported .ts modules itself.
import { basemapStatus } from '../src/map/basemapStatus.ts';
import { satelliteLook, satelliteStatus } from '../src/map/satelliteStatus.ts';
import { openingView } from '../src/map/openingView.ts';
import { areaLoad } from '../src/map/areaLoad.ts';
import { fogLevelInView, fogLevelPick } from '../src/map/fogLevels.ts';
import { placeLabel } from '../src/map/fogPlaceLabel.ts';
import { dateFilterBounds, dateFilterLabel, setDateFilter } from '../src/ui/dateFilter.ts';
import { distanceBounds, nextDistanceFilter, passesFilters, typeFacets } from '../src/ui/activityFacets.ts';
import { applyEdit, chopOp, cumulativeDistances, cutOp, foldEdit, moveOp, splitIndex, splitPoint } from '../src/ui/editTrackOps.ts';
import { insertionPoint, needsLift } from '../src/map/mapLayers.ts';
import { pendingAnswer, pendingBatches, pendingChange, pendingWatched } from '../src/map/pending.ts';
import { deleteDone } from '../src/apiError.ts';
import { clusterPoints, photoMarkerLayout, photoMarkerSize } from '../src/map/photoClusters.ts';
import { photoGroupAction, photoScopeFor } from '../src/map/photoMarkerItems.ts';
import { distanceParts, durationParts, totalDistanceParts } from '../src/ui/formatParts.ts';
import { fractionAt, photoTrack, pointAt, startFraction } from '../src/ui/photoTrack.ts';
import { clampView, fitSize, panBy, zoomAt } from '../src/ui/photoZoom.ts';
import { activityTimeZone } from '../src/ui/timeZone.ts';
import { boldTracks, invertedChecks, toggledVisibility, toolbarTarget } from '../src/map/selection.ts';
import { statsCardPlacement, statsOffered } from '../src/map/exportStats.ts';
import { emptySelection, initialSession, mapSessionReducer } from '../src/map/session.ts';
import { cameraEnd, cameraStep, cardFor, nextStep, stepChanges, tourStart } from '../src/ui/tour/tourRules.ts';


const sorted = (set) => [...set].sort();

// The cases say tracks and trips; the map code still says activities and stories until it is
// renamed. Maps the tab and card ids across, both ways, and nothing else.
const OLD = { tracks: 'activities', trips: 'stories' };
const NEW = { activities: 'tracks', stories: 'trips' };
const id = (names) => (value) => (typeof value === 'string' ? (names[value] ?? value) : value);
const ids = (names) => (value) => {
  if (!value || typeof value !== 'object') return value;
  const out = { ...value };
  for (const key of ['tab', 'card']) if (key in out) out[key] = id(names)(out[key]);
  if (Array.isArray(out.cards)) out.cards = out.cards.map(id(names));
  return out;
};
const toOld = ids(OLD);
const toNew = ids(NEW);
const SESSION_EVENT = { tripEntered: 'storyEntered', tripExited: 'storyExited' };

export const rules = {
  openingView: ({ boxes, viewport }) => openingView(boxes, viewport),
  areaLoad: ({ zoom, listed, total }) => areaLoad(zoom, listed, total ?? null),
  fogLevelInView: ({ levels, zoom, locked }) => fogLevelInView(levels, zoom, locked ?? null),
  fogLevelPick: ({ levels, zoom, locked, picked }) => fogLevelPick(levels, zoom, locked ?? null, picked),
  fogPlaceLabel: ({ props, catalog }) => placeLabel(props, (key) => catalog.includes(key)),
  dateFilterSet: ({ current, end, value, bounds }) => setDateFilter({ after: current.after ?? null, before: current.before ?? null }, end, value ?? null, bounds),
  dateFilterLabel: ({ after, before }) => dateFilterLabel({ after: after ?? null, before: before ?? null }),
  dateFilterBounds: ({ earliest, latest, today }) => dateFilterBounds(earliest ?? null, latest ?? null, today),
  satelliteStatus: ({ on, loaded, failed, waitedMs }) => {
    const status = satelliteStatus(loaded, failed, waitedMs);
    return { status, look: satelliteLook(on, status) };
  },
  tourStart: ({ requested, isDemo, hasTracks, seen }) => tourStart({ requested, isDemo, hasActivities: hasTracks ?? null, seen: toOld(seen) }),
  tourCard: ({ event, seen, touring }) => id(NEW)(cardFor(toOld(event), toOld(seen), touring)),
  tourCamera: ({ start, shown, current, step }) => {
    const toView = (v) => (v ? { center: [v.lon, v.lat], zoom: v.zoom } : null);
    const fromView = (v) => (v ? { lon: v.center[0], lat: v.center[1], zoom: v.zoom } : null);
    const camera = { start: toView(start), shown: toView(shown) };
    if (!step) return { start: null, shown: null, move: fromView(cameraEnd(camera)) };
    const { camera: next, move } = cameraStep(camera, { view: toView(step.view), tab: id(OLD)(step.tab) }, toView(current));
    return { start: fromView(next.start), shown: fromView(next.shown), move: fromView(move) };
  },
  tourStep: ({ now, step, restore }) => toNew(stepChanges(toOld(now), toOld(step ?? null), toOld(restore))),
  tourNextStep: ({ shown, from, dir }) => {
    const steps = shown.map(() => ({ anchor: 'shared' }));
    return nextStep(steps, from, dir, (step) => shown[steps.indexOf(step)]);
  },
  pendingCheck: ({ pending, awaiting, listed, stillPending }) => {
    const watched = pendingWatched(pending, awaiting);
    const { moved, finished } = pendingAnswer(watched, stillPending, new Set(listed));
    return { watched, moved, finished: sorted(finished) };
  },
  pendingBatches: ({ ids, size }) => pendingBatches(ids, size),
  deleteDone: ({ status }) => deleteDone(status),
  pendingChange: ({ previous, now, awaiting, listed }) => {
    const change = pendingChange(new Set(previous), now, new Set(awaiting), new Set(listed));
    return { started: change.started, finished: change.finished, left: sorted(change.left), landed: sorted(change.landed), awaiting: sorted(change.awaiting), pending: sorted(change.pending) };
  },
  boldTracks: ({ checked, focused }) => boldTracks(new Set(checked), focused ?? null),
  toolbarTarget: ({ checked, focused }) => sorted(toolbarTarget(new Set(checked), focused ?? null)),
  statsOffered: ({ checked, tripId }) => statsOffered(new Set(checked), tripId ?? null),
  statsCardPlacement: ({ width, height, card }) => statsCardPlacement(width, height, card),
  targetVisibility: ({ hidden, target }) => sorted(toggledVisibility(new Set(hidden), new Set(target))),
  photoScope: ({ mode, editWindowIds, focused, tripId }) => {
    const scope = photoScopeFor(mode, editWindowIds ?? null, focused ?? null, tripId ?? null);
    return scope === null ? null : 'activity' in scope ? { track: scope.activity } : { trip: scope.story };
  },
  photoGroup: ({ photos }) => photoGroupAction(photos),
  distanceBounds: ({ tracks }) => distanceBounds(tracks),
  distanceFilter: ({ bounds, current, knob, value }) => nextDistanceFilter(bounds, current, knob, value),
  typeFacets: ({ tracks, distanceFilter }) => typeFacets(tracks, distanceFilter ?? null),
  passesFilters: ({ track, excludedTypes, distanceFilter }) => passesFilters(track, new Set(excludedTypes), distanceFilter ?? null),
  trackZone: ({ own, account }) => activityTimeZone(own ?? undefined, account ?? undefined) ?? null,
  photoClusters: ({ points, radius }) => clusterPoints(points, radius),
  photoMarkerSize: ({ zoom }) => photoMarkerSize(zoom),
  basemapStatus: ({ loaded, failed, waitedMs }) => basemapStatus(loaded, failed, waitedMs),
  photoMarkerLayout: ({ points, zoom, activeId, loneId, width, height, scale }) =>
    photoMarkerLayout(points, zoom, activeId ?? null, loneId ?? null, { width, height }, scale),
  photoRoutePoint: ({ points, fraction }) => pointAt(photoTrack(points), fraction),
  photoRouteFraction: ({ points, t }) => fractionAt(photoTrack(points), t),
  photoRouteStart: ({ points, anchor, placed, anchors }) =>
    startFraction(photoTrack(points), anchor ?? null, new Map(Object.entries(placed)), new Map(Object.entries(anchors))),
  photoFit: ({ image, stage }) => fitSize(image, stage),
  photoZoom: ({ view, factor, point, fitted, stage }) => zoomAt(view, factor, point, fitted, stage),
  photoPan: ({ view, dx, dy, fitted, stage }) => panBy(view, dx, dy, fitted, stage),
  photoClamp: ({ view, fitted, stage }) => clampView(view, fitted, stage),
  distanceParts: ({ meters, system }) => distanceParts(meters, system),
  totalDistanceParts: ({ meters, system }) => totalDistanceParts(meters, system),
  durationParts: ({ seconds }) => durationParts(seconds),
  editRouteFold: ({ base, ops }) => foldEdit(base ?? null, ops),
  editRouteApply: ({ points, edit }) => applyEdit(points, edit),
  editRouteChop: ({ visible, lo, hi }) => chopOp(visible, lo, hi),
  editRouteCut: ({ visible, lo, hi }) => cutOp(visible, lo, hi),
  editRouteSplitIndex: ({ visible, lo, hi }) => splitIndex(visible, lo, hi),
  editRouteSplitPoint: ({ ops }) => splitPoint(ops),
  editRouteMove: ({ t, lon, lat }) => moveOp(t, lon, lat),
  editRouteDistances: ({ points }) => cumulativeDistances(points),
  layerInsertion: ({ current, order, id, own, fallback }) => insertionPoint(current, order, id, new Set(own), fallback ?? undefined) ?? null,
  layerLift: ({ current, id, own }) => needsLift(current, id, new Set(own)),
  panelState: ({ tracks, state, event }) => {
    const selection = {
      checked: new Set(state.checked ?? []),
      focused: state.focused ?? null,
      hidden: new Set(state.hidden ?? []),
      excludedTypes: new Set(state.excludedTypes ?? []),
      distanceFilter: state.distanceFilter ?? null,
    };
    const listed = tracks.filter((a) => passesFilters(a, selection.excludedTypes, selection.distanceFilter));
    // The master checkbox's and Invert's events, as useSelectionActions.ts sends them.
    const sent = {
      checkAll: () => ({ type: 'checkedSet', ids: listed.map((a) => a.id) }),
      checksCleared: () => ({ type: 'checkedSet', ids: [] }),
      checksInverted: () => ({ type: 'checkedSet', ids: invertedChecks(listed, selection.checked) }),
      typeToggled: () => ({ ...event, activities: tracks }),
      distanceSet: () => ({ ...event, activities: tracks }),
    }[event.type]?.() ?? event;
    const next = mapSessionReducer({ ...initialSession(null), selection }, sent).selection;
    return {
      checked: sorted(next.checked),
      focused: next.focused,
      hidden: sorted(next.hidden),
      excludedTypes: sorted(next.excludedTypes),
      distanceFilter: next.distanceFilter,
    };
  },
  webSession: ({ state, event }) => {
    const start = {
      ...initialSession(state.tripId ?? null),
      dates: { after: state.dates?.after ?? null, before: state.dates?.before ?? null },
      area: state.area ?? null,
      selection: { ...emptySelection(), checked: new Set(state.checked ?? []), hidden: new Set(state.hidden ?? []), excludedTypes: new Set(state.excludedTypes ?? []) },
    };
    const next = mapSessionReducer(start, { ...event, type: SESSION_EVENT[event.type] ?? event.type });
    return {
      dates: next.dates,
      area: next.area,
      ...(next.storyId !== null && { tripId: next.storyId }),
      checked: sorted(next.selection.checked),
      hidden: sorted(next.selection.hidden),
      excludedTypes: sorted(next.selection.excludedTypes),
      flyRequest: next.flyRequest,
    };
  },
};
