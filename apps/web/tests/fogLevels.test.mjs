// Fog's level control: each level's layers' zoom range, and what the control calls each level.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { exploredCount, levelLabelKey, levelZoomRanges } from '../src/map/fogLevels.ts';

const levels = [
  { level: 'country', below: 3, layers: ['country-fill', 'country-border'] },
  { level: 'county', from: 6, below: 8, layers: ['county-fill'] },
  { level: 'exact', from: 11, layers: ['veil'] },
];

test('following the zoom, every level draws in its band', () => {
  assert.deepEqual(levelZoomRanges(levels, null), {
    'country-fill': [0, 3],
    'country-border': [0, 3],
    'county-fill': [6, 8],
    veil: [11, 24],
  });
});

test('a locked level draws at every zoom, and no other level draws', () => {
  assert.deepEqual(levelZoomRanges(levels, 'county'), {
    'country-fill': [24, 24],
    'country-border': [24, 24],
    'county-fill': [0, 24],
    veil: [24, 24],
  });
});

test('a lock on a level the document no longer has follows the zoom', () => {
  assert.deepEqual(levelZoomRanges(levels, 'region'), levelZoomRanges(levels, null));
});

test("a level is named in its country's words where the catalog has them", () => {
  const has = (key) => key === 'map.fog.type.state' || key === 'map.fog.type.department';
  assert.equal(levelLabelKey('region', 'state', has), 'map.fog.type.state');
  assert.equal(levelLabelKey('county', 'department', has), 'map.fog.type.department');
  assert.equal(levelLabelKey('county', 'military_area', has), 'map.fog.level.county');
  assert.equal(levelLabelKey('region', '', has), 'map.fog.level.region');
  // Only regions and counties take a country's word: a city is called a city.
  assert.equal(levelLabelKey('city', 'state', has), 'map.fog.level.city');
  assert.equal(levelLabelKey('exact', undefined, has), 'map.fog.level.exact');
});

test('each level but Exact counts the places explored on it', () => {
  const explored = { countries: 5, regions: 22, counties: 31, cities: 128 };
  assert.deepEqual(['country', 'region', 'county', 'city', 'exact'].map((l) => exploredCount(explored, l)), [5, 22, 31, 128, null]);
});
