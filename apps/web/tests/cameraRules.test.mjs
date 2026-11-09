import { test } from 'node:test';
import assert from 'node:assert/strict';
import { listQuery, tracksQuery } from '../src/map/activityQuery.ts';
import { firstListFit } from '../src/map/cameraRules.ts';

const activity = (id, startedAt, { bbox = [0, 0, 1, 1], pending = false } = {}) => ({ id, startedAt, bbox, pending });
const older = activity('older', '2026-09-01T08:00:00Z');
const newer = activity('newer', '2026-09-03T08:00:00Z');

test("inside a Story the first list fits all of it, Pending left out", () => {
  const pending = activity('pending', '2026-09-05T08:00:00Z', { pending: true });
  assert.deepEqual(firstListFit([older, newer, pending], 's', false), [older, newer]);
});

test('a Story with nothing drawn waits', () => {
  assert.equal(firstListFit([activity('x', '2026-09-01T00:00:00Z', { bbox: null })], 's', false), null);
});

test('without a Story, or with a view in the URL, the list moves no camera', () => {
  assert.deepEqual(firstListFit([older, newer], null, false), []);
  assert.deepEqual(firstListFit([older, newer], 's', true), []);
});

test('the list is the open Story, else the area under Dates; the tracks never take the area', () => {
  const dates = { after: '2026-09-01', before: null };
  const area = [8, 47, 9, 48];
  assert.deepEqual(listQuery('s', dates, area), { story: { story: 's' } });
  assert.deepEqual(listQuery(null, dates, area), { area: { from: '2026-09-01', bbox: area } });
  assert.equal(listQuery(null, dates, null), null);
  assert.deepEqual(tracksQuery(null, { after: null, before: '2026-09-02' }), { to: '2026-09-02' });
  assert.deepEqual(tracksQuery(null, { after: null, before: null }), {});
  assert.deepEqual(tracksQuery('s', dates), { story: 's' });
});
