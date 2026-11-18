import { test } from 'node:test';
import assert from 'node:assert/strict';
import { bandWithin, nextDistanceFilter } from '../src/ui/activityFacets.ts';

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
