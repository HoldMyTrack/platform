// The tooltip for the outline under the pointer in Fog.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { placeLabel } from '../src/map/fogPlaceLabel.ts';

const catalog = new Set(['map.fog.type.town', 'map.fog.type.department', 'map.fog.type.state', 'map.fog.count.state.other', 'map.fog.count.parish.other']);
const has = (key) => catalog.has(key);

test('an outline is named with its own kind, the places it lies in and whether it is explored', () => {
  assert.deepEqual(placeLabel({ kind: 'city', type: 'town', name: 'Parma', within: 'Cuyahoga County, Ohio', visited: true }, has), {
    name: 'Parma',
    kindKey: 'map.fog.type.town',
    within: 'Cuyahoga County, Ohio',
    visitedKey: 'map.fog.place.visited',
    counts: [],
  });
  assert.equal(placeLabel({ kind: 'county', type: 'department', name: 'Calvados', within: 'Normandy' }, has).kindKey, 'map.fog.type.department');
  assert.equal(placeLabel({ kind: 'region', name: 'Ohio', visited: 'false' }, has).visitedKey, 'map.fog.place.unvisited');
});

test('a kind its catalog has no word for, or none, is called by the level', () => {
  assert.equal(placeLabel({ kind: 'county', type: 'military_area', name: 'X' }, has).kindKey, 'map.fog.place.county');
  assert.equal(placeLabel({ kind: 'region', name: 'Aruba' }, has).kindKey, 'map.fog.place.region');
  assert.equal(placeLabel({ kind: 'country', name: 'France' }, has).within, '');
});

test('the sea, an unknown kind or a missing name has no tooltip', () => {
  assert.equal(placeLabel({ kind: 'sea', visited: false }, has), null);
  assert.equal(placeLabel({ kind: 'township', name: 'X' }, has), null);
  assert.equal(placeLabel({ kind: 'city', name: '' }, has), null);
  assert.equal(placeLabel({}, has), null);
});

test("a place counts the places below it in its country's words, else the level's", () => {
  const counts = (props) => placeLabel({ kind: 'country', name: 'X', visited: true, ...props }, has).counts;
  assert.deepEqual(
    counts({ regions: 9, regions_total: 56, counties: 120, counties_total: 3142, cities: 840, cities_total: 29858, region_word: 'state', county_word: 'county' }),
    [
      { key: 'map.fog.count.state', explored: 9, total: 56 },
      // No plural for 'county' in this catalog: the level's own word.
      { key: 'map.fog.count.county', explored: 120, total: 3142 },
      { key: 'map.fog.count.city', explored: 840, total: 29858 },
    ],
  );
  assert.deepEqual(counts({ counties: 3, counties_total: 4, county_word: 'parish' }), [{ key: 'map.fog.count.parish', explored: 3, total: 4 }]);
  // None of a level, or no count at all (a city, a stand-in): nothing for it.
  assert.deepEqual(counts({ regions: 0, regions_total: 0, cities: 2, cities_total: 5 }), [{ key: 'map.fog.count.city', explored: 2, total: 5 }]);
  assert.deepEqual(counts({}), []);
});
