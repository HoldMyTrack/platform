// Covers docs/SPEC.md FR-4.8: the focused activity's bands and its direction arrows' route.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { bandsData } from '../src/map/trackBands.ts';

const point = (lon, lat) => ({ lon, lat, speedMps: 1, timeS: 0 });

test('a line per band run, then the whole route in recording order', () => {
  const points = [point(0, 0), point(1, 0), point(2, 0)];
  const { features } = bandsData({ activityId: 'a', points, bands: [{ band: 0, start: 0, end: 1 }, { band: 4, start: 1, end: 2 }] });
  assert.deepEqual(features.map((f) => f.properties), [{ band: 0 }, { band: 4 }, { route: true }]);
  assert.deepEqual(features[1].geometry.coordinates, [[1, 0], [2, 0]]);
  assert.deepEqual(features[2].geometry.coordinates, [[0, 0], [1, 0], [2, 0]]);
});

test('no route for a track too short to have a direction', () => {
  assert.deepEqual(bandsData({ activityId: 'a', points: [point(0, 0)], bands: [] }).features, []);
});
