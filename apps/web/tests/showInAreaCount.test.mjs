import { test } from 'node:test';
import assert from 'node:assert/strict';
import { areaCount } from '../src/ui/showInAreaCount.ts';

const load = { categories: ['waterfall', 'viewpoint'], spotCategories: ['waterfall', 'viewpoint', 'viewpoint'], total: 3 };

test('the same categories say what the load found', () => {
  assert.deepEqual(areaCount(load, ['viewpoint', 'waterfall']), { shown: 3, total: 3 });
  assert.deepEqual(areaCount({ ...load, total: 2500 }, ['waterfall', 'viewpoint']), { shown: 3, total: 2500 });
});

test('a category switched off counts only the ones still on', () => {
  assert.deepEqual(areaCount(load, ['viewpoint']), { shown: 2, total: 2 });
});

test('a category switched off from a load cut at the limit brings the button back', () => {
  assert.equal(areaCount({ ...load, total: 2500 }, ['viewpoint']), null);
});

test('a category switched on since brings the button back', () => {
  assert.equal(areaCount(load, ['waterfall', 'viewpoint', 'peak']), null);
});
