import { test } from 'node:test';
import assert from 'node:assert/strict';
import { bandWithin, emptyListReason, nextDistanceFilter } from '../src/ui/trackFacets.ts';

const bounds = { min: 30000, max: 50000 };

test('a band inside the bounds is drawn as it is', () => {
  assert.deepEqual(bandWithin(bounds, { min: 35000, max: 40000 }), { min: 35000, max: 40000 });
});

test('a band partly outside the bounds is drawn up to them', () => {
  assert.deepEqual(bandWithin(bounds, { min: 20000, max: 40000 }), { min: 30000, max: 40000 });
});

test('a band wholly outside the bounds is drawn at the nearer end', () => {
  assert.deepEqual(bandWithin(bounds, { min: 5000, max: 20000 }), { min: 30000, max: 30000 });
});

test('a knob dragged from a drawn band stays where it was dragged', () => {
  const drawn = bandWithin(bounds, { min: 5000, max: 20000 });
  assert.deepEqual(nextDistanceFilter(bounds, drawn, 'max', 45000), { min: 30000, max: 45000 });
});

test('an empty list blames the filters only when one is set', () => {
  const noDates = { after: null, before: null };
  assert.equal(emptyListReason(new Set(), null, noDates), 'area');
  assert.equal(emptyListReason(new Set(['running']), null, noDates), 'filters');
  assert.equal(emptyListReason(new Set(), { min: 1000, max: 5000 }, noDates), 'filters');
  assert.equal(emptyListReason(new Set(), null, { after: '2026-10-01', before: null }), 'filters');
});
