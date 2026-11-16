import { test } from 'node:test';
import assert from 'node:assert/strict';
import { NO_OVERLAYS, layersCount, readOverlays, toggleLayer, togglePlace } from '../src/map/overlays.ts';
import { SPOT_CATEGORY_WIRE } from '../src/map/spotsGroup.ts';

test('nothing stored is the default, or the two toggles from before the Layers menu', () => {
  assert.deepEqual(readOverlays(null, false, false), NO_OVERLAYS);
  const legacy = readOverlays(null, true, true);
  assert.equal(legacy.bikePaths, true);
  assert.deepEqual(legacy.spots, SPOT_CATEGORY_WIRE);
});

test("a choice saved before Places had its own checkbox takes the Layers one's", () => {
  const saved = (enabled) => JSON.stringify({ roads: true, enabled, spots: ['waterfall'] });
  assert.equal(readOverlays(saved(false), false, false).placesEnabled, false);
  assert.equal(readOverlays(saved(true), false, false).placesEnabled, true);
  // Saved since the split, each checkbox stands on its own.
  const split = readOverlays(JSON.stringify({ enabled: false, placesEnabled: true, spots: ['waterfall'] }), false, false);
  assert.equal(split.enabled, false);
  assert.equal(split.placesEnabled, true);
});

test('a stored record keeps only known categories, and one that does not parse is the default', () => {
  assert.deepEqual(readOverlays(JSON.stringify({ spots: ['waterfall', 'volcano'] }), false, false).spots, ['waterfall']);
  assert.deepEqual(readOverlays('{', false, false), NO_OVERLAYS);
  assert.deepEqual(readOverlays('null', false, false), NO_OVERLAYS);
});

test('the Layers count is roads and paths, never places', () => {
  assert.equal(layersCount(NO_OVERLAYS), 1);
  assert.equal(layersCount({ ...NO_OVERLAYS, bikePaths: true, mtbTrails: true, spots: ['waterfall'] }), 3);
});

test('ticking a road or path turns the Layers checkbox back on; unticking leaves it off', () => {
  const off = { ...NO_OVERLAYS, enabled: false };
  const picked = toggleLayer(off, 'bikePaths');
  assert.equal(picked.bikePaths, true);
  assert.equal(picked.enabled, true);
  const unpicked = toggleLayer(off, 'roads');
  assert.equal(unpicked.roads, false);
  assert.equal(unpicked.enabled, false);
  // The Places checkbox is the other menu's.
  assert.equal(toggleLayer({ ...off, placesEnabled: false }, 'mtbTrails').placesEnabled, false);
});

test('ticking a place turns the Places checkbox back on and keeps the categories in order', () => {
  const off = { ...NO_OVERLAYS, placesEnabled: false, enabled: false, spots: ['waterfall'] };
  const picked = togglePlace(off, 'playground');
  assert.deepEqual(picked.spots, ['playground', 'waterfall']);
  assert.equal(picked.placesEnabled, true);
  assert.equal(picked.enabled, false, 'the Layers checkbox untouched');
  const unpicked = togglePlace(off, 'waterfall');
  assert.deepEqual(unpicked.spots, []);
  assert.equal(unpicked.placesEnabled, false);
});
