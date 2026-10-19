import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
// Plain .mjs so tsc leaves it alone; Node strips the types from the imported .ts modules itself.
import { defaultRange } from '../src/map/defaultRange.ts';
import { distanceBounds, nextDistanceFilter, passesFilters, typeFacets } from '../src/ui/activityFacets.ts';
import { applyEdit, chopOp, cumulativeDistances, cutOp, foldEdit, moveOp, splitIndex, splitPoint } from '../src/ui/editTrackOps.ts';
import { insertionPoint, needsLift } from '../src/map/mapLayers.ts';
import { pendingChange } from '../src/map/pending.ts';
import { clusterPoints, photoMarkerSize } from '../src/map/photoClusters.ts';
import { photoGroupAction, photoScopeFor } from '../src/map/photoMarkerItems.ts';
import { distanceParts, durationParts, totalDistanceParts } from '../src/ui/formatParts.ts';
import { fractionAt, photoTrack, pointAt, startFraction } from '../src/ui/photoTrack.ts';
import { clampView, fitSize, panBy, zoomAt } from '../src/ui/photoZoom.ts';
import { shiftRange } from '../src/ui/rangeShift.ts';
import { activityTimeZone } from '../src/ui/timeZone.ts';
import { toggledVisibility, toolbarTarget } from '../src/map/selection.ts';
import { emptySelection, initialSession, mapSessionReducer } from '../src/map/session.ts';

// The cases every client runs (testdata/client-rules/README.md). Mounted at /testdata in the
// web container, which this path also reaches.
const dir = new URL('../../../testdata/client-rules/', import.meta.url);
const sorted = (set) => [...set].sort();

const rules = {
  defaultRange: ({ visibleDays, earliest, today }) => defaultRange(visibleDays.map((date) => ({ date })), earliest ?? null, today),
  pendingChange: ({ previous, now, awaiting }) => {
    const change = pendingChange(new Set(previous), now, new Set(awaiting));
    return { started: change.started, finished: change.finished, left: sorted(change.left), landed: sorted(change.landed), awaiting: sorted(change.awaiting) };
  },
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

/** Equal as JSON, numbers within `tolerance`. */
function assertClose(actual, expected, tolerance, path = '') {
  if (typeof expected === 'number' && typeof actual === 'number') {
    assert.ok(Math.abs(actual - expected) <= tolerance, `${path || 'value'}: ${actual} is not within ${tolerance} of ${expected}`);
  } else if (Array.isArray(expected)) {
    assert.ok(Array.isArray(actual) && actual.length === expected.length, `${path || 'value'}: ${JSON.stringify(actual)} is not ${JSON.stringify(expected)}`);
    expected.forEach((item, i) => assertClose(actual[i], item, tolerance, `${path}[${i}]`));
  } else if (expected !== null && typeof expected === 'object') {
    assert.ok(actual !== null && typeof actual === 'object' && !Array.isArray(actual), `${path || 'value'}: ${JSON.stringify(actual)} is not an object`);
    // A missing field means the same as null.
    for (const key of new Set([...Object.keys(expected), ...Object.keys(actual)])) {
      assertClose(actual[key] ?? null, expected[key] ?? null, tolerance, `${path}.${key}`);
    }
  } else {
    assert.equal(actual, expected, path || 'value');
  }
}

const files = readdirSync(dir).filter((name) => name.endsWith('.json'));

test('every shared rule file has a web implementation', () => {
  for (const name of files) {
    const { rule } = JSON.parse(readFileSync(new URL(name, dir), 'utf8'));
    assert.ok(rules[rule], `${name}: no web implementation of ${rule}`);
  }
});

for (const name of files) {
  const { rule, cases, tolerance: fileTolerance } = JSON.parse(readFileSync(new URL(name, dir), 'utf8'));
  for (const { name: caseName, input, expected, tolerance } of cases) {
    test(`${rule}: ${caseName}`, () => {
      if (expected?.throws === true) {
        assert.throws(() => rules[rule](input));
        return;
      }
      const actual = rules[rule](input);
      const within = tolerance ?? fileTolerance;
      if (within === undefined) assert.deepEqual(actual, expected);
      else assertClose(actual, expected, within);
    });
  }
}
