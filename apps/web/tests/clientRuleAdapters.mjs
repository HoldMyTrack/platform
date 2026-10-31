// Each shared rule (testdata/client-rules/README.md) as a function of a case's input, for the
// suite and for scripts/generate-rule-cases.mjs. Plain .mjs so tsc leaves it alone; Node strips
// the types from the imported .ts modules itself.
import { basemapStatus } from '../src/map/basemapStatus.ts';
import { defaultRange } from '../src/map/defaultRange.ts';
import { distanceBounds, nextDistanceFilter, passesFilters, typeFacets } from '../src/ui/activityFacets.ts';
import { applyEdit, chopOp, cumulativeDistances, cutOp, foldEdit, moveOp, splitIndex, splitPoint } from '../src/ui/editTrackOps.ts';
import { insertionPoint, needsLift } from '../src/map/mapLayers.ts';
import { pendingBatches, pendingChange, pendingMoved, pendingWatched } from '../src/map/pending.ts';
import { clusterPoints, photoMarkerLayout, photoMarkerSize } from '../src/map/photoClusters.ts';
import { photoGroupAction, photoScopeFor } from '../src/map/photoMarkerItems.ts';
import { distanceParts, durationParts, totalDistanceParts } from '../src/ui/formatParts.ts';
import { fractionAt, photoTrack, pointAt, startFraction } from '../src/ui/photoTrack.ts';
import { clampView, fitSize, panBy, zoomAt } from '../src/ui/photoZoom.ts';
import { shiftRange } from '../src/ui/rangeShift.ts';
import { sliderBoundaries, sliderLayout, sliderMoveKnob, sliderPanLand, sliderTicks, sliderWindowFit } from '../src/ui/sliderRules.ts';
import { activityTimeZone } from '../src/ui/timeZone.ts';
import { boldTracks, invertedChecks, toggledVisibility, toolbarTarget } from '../src/map/selection.ts';
import { emptySelection, initialSession, mapSessionReducer } from '../src/map/session.ts';
import { cameraEnd, cameraStep, cardFor, nextStep, stepChanges, tourStart } from '../src/ui/tour/tourRules.ts';


const sorted = (set) => [...set].sort();

export const rules = {
  tourStart: ({ requested, isDemo, hasActivities, seen }) => tourStart({ requested, isDemo, hasActivities: hasActivities ?? null, seen }),
  tourCard: ({ event, seen, touring }) => cardFor(event, seen, touring),
  tourCamera: ({ start, shown, current, step }) => {
    const toView = (v) => (v ? { center: [v.lon, v.lat], zoom: v.zoom } : null);
    const fromView = (v) => (v ? { lon: v.center[0], lat: v.center[1], zoom: v.zoom } : null);
    const camera = { start: toView(start), shown: toView(shown) };
    if (!step) return { start: null, shown: null, move: fromView(cameraEnd(camera)) };
    const { camera: next, move } = cameraStep(camera, { view: toView(step.view), tab: step.tab }, toView(current));
    return { start: fromView(next.start), shown: fromView(next.shown), move: fromView(move) };
  },
  tourStep: ({ now, step, restore }) => stepChanges(now, step ?? null, restore),
  tourNextStep: ({ shown, from, dir }) => {
    const steps = shown.map(() => ({ anchor: 'shared' }));
    return nextStep(steps, from, dir, (step) => shown[steps.indexOf(step)]);
  },
  defaultRange: ({ visibleDays, earliest, today }) => defaultRange(visibleDays.map((date) => ({ date })), earliest ?? null, today),
  pendingCheck: ({ listed, awaiting, stillPending }) => {
    const watched = pendingWatched(listed, new Set(awaiting));
    return { watched, moved: pendingMoved(watched, stillPending) };
  },
  pendingBatches: ({ ids, size }) => pendingBatches(ids, size),
  pendingChange: ({ previous, now, awaiting }) => {
    const change = pendingChange(new Set(previous), now, new Set(awaiting));
    return { started: change.started, finished: change.finished, left: sorted(change.left), landed: sorted(change.landed), awaiting: sorted(change.awaiting) };
  },
  boldTracks: ({ checked, focused }) => boldTracks(new Set(checked), focused ?? null),
  toolbarTarget: ({ checked, focused }) => sorted(toolbarTarget(new Set(checked), focused ?? null)),
  targetVisibility: ({ hidden, target }) => sorted(toggledVisibility(new Set(hidden), new Set(target))),
  photoScope: ({ mode, editWindowIds, focused, storyId }) => photoScopeFor(mode, editWindowIds ?? null, focused ?? null, storyId ?? null),
  photoGroup: ({ photos }) => photoGroupAction(photos),
  rangeShift: ({ days, hasEarlier, range, dir }) => shiftRange(days, hasEarlier, range, dir),
  distanceBounds: ({ activities }) => distanceBounds(activities),
  distanceFilter: ({ bounds, current, knob, value }) => nextDistanceFilter(bounds, current, knob, value),
  typeFacets: ({ activities, distanceFilter }) => typeFacets(activities, distanceFilter ?? null),
  passesFilters: ({ activity, excludedTypes, distanceFilter }) => passesFilters(activity, new Set(excludedTypes), distanceFilter ?? null),
  activityZone: ({ own, account }) => activityTimeZone(own ?? undefined, account ?? undefined) ?? null,
  photoClusters: ({ points, radius }) => clusterPoints(points, radius),
  photoMarkerSize: ({ zoom }) => photoMarkerSize(zoom),
  basemapStatus: ({ loaded, failed, waitedMs }) => basemapStatus(loaded, failed, waitedMs),
  photoMarkerLayout: ({ points, zoom, activeId, loneId, width, height, scale }) =>
    photoMarkerLayout(points, zoom, activeId ?? null, loneId ?? null, { width, height }, scale),
  photoTrackPoint: ({ points, fraction }) => pointAt(photoTrack(points), fraction),
  photoTrackFraction: ({ points, t }) => fractionAt(photoTrack(points), t),
  photoTrackStart: ({ points, anchor, placed, anchors }) =>
    startFraction(photoTrack(points), anchor ?? null, new Map(Object.entries(placed)), new Map(Object.entries(anchors))),
  photoFit: ({ image, stage }) => fitSize(image, stage),
  photoZoom: ({ view, factor, point, fitted, stage }) => zoomAt(view, factor, point, fitted, stage),
  photoPan: ({ view, dx, dy, fitted, stage }) => panBy(view, dx, dy, fitted, stage),
  photoClamp: ({ view, fitted, stage }) => clampView(view, fitted, stage),
  distanceParts: ({ meters, system }) => distanceParts(meters, system),
  totalDistanceParts: ({ meters, system }) => totalDistanceParts(meters, system),
  durationParts: ({ seconds }) => durationParts(seconds),
  editTrackFold: ({ base, ops }) => foldEdit(base ?? null, ops),
  editTrackApply: ({ points, edit }) => applyEdit(points, edit),
  editTrackChop: ({ visible, lo, hi }) => chopOp(visible, lo, hi),
  editTrackCut: ({ visible, lo, hi }) => cutOp(visible, lo, hi),
  editTrackSplitIndex: ({ visible, lo, hi }) => splitIndex(visible, lo, hi),
  editTrackSplitPoint: ({ ops }) => splitPoint(ops),
  editTrackMove: ({ t, lon, lat }) => moveOp(t, lon, lat),
  editTrackDistances: ({ points }) => cumulativeDistances(points),
  layerInsertion: ({ current, order, id, own, fallback }) => insertionPoint(current, order, id, new Set(own), fallback ?? undefined) ?? null,
  layerLift: ({ current, id, own }) => needsLift(current, id, new Set(own)),
  panelState: ({ activities, state, event }) => {
    const selection = {
      checked: new Set(state.checked ?? []),
      focused: state.focused ?? null,
      hidden: new Set(state.hidden ?? []),
      excludedTypes: new Set(state.excludedTypes ?? []),
      distanceFilter: state.distanceFilter ?? null,
    };
    const listed = activities.filter((a) => passesFilters(a, selection.excludedTypes, selection.distanceFilter));
    // The master checkbox's and Invert's events, as useSelectionActions.ts sends them.
    const sent = {
      checkAll: () => ({ type: 'checkedSet', ids: listed.map((a) => a.id) }),
      checksCleared: () => ({ type: 'checkedSet', ids: [] }),
      checksInverted: () => ({ type: 'checkedSet', ids: invertedChecks(listed, selection.checked) }),
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
  sliderLayout: ({ width, finePointer }) => sliderLayout(width, finePointer),
  sliderBoundaries: ({ days, canPanEarlier, canPanLater, range }) => sliderBoundaries({ days, canPanEarlier, canPanLater }, range),
  sliderMoveKnob: ({ days, canPanEarlier, canPanLater, range, knob, boundary }) =>
    sliderMoveKnob({ days, canPanEarlier, canPanLater }, range, knob, boundary),
  sliderTicks: ({ days }) => sliderTicks(days),
  sliderPanLand: ({ days, range, start, end }) => sliderPanLand(days, range, start, end),
  sliderWindowFit: ({ count, windowDays, left, first, last, dir }) => sliderWindowFit(count, windowDays, left, first, last, dir),
  session: ({ state, event }) => {
    const start = {
      ...initialSession(state.storyId ?? null),
      range: state.range ?? null,
      userPicked: state.userPicked ?? false,
      selection: { ...emptySelection(), checked: new Set(state.checked ?? []), hidden: new Set(state.hidden ?? []), excludedTypes: new Set(state.excludedTypes ?? []) },
    };
    const next = mapSessionReducer(start, event);
    return {
      range: next.range,
      userPicked: next.userPicked,
      ...(next.storyId !== null && { storyId: next.storyId }),
      checked: sorted(next.selection.checked),
      hidden: sorted(next.selection.hidden),
      excludedTypes: sorted(next.selection.excludedTypes),
      flyRequest: next.flyRequest,
    };
  },
};
