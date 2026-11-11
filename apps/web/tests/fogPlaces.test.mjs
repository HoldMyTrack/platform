// The tooltip for the outline under the pointer in Fog.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { placeLabel } from '../src/map/fogPlaceLabel.ts';

const catalog = new Set(['map.fog.type.town', 'map.fog.type.department', 'map.fog.type.state']);
const has = (key) => catalog.has(key);

test('an outline is named with its own kind, the places it lies in and whether it is explored', () => {
  assert.deepEqual(placeLabel({ kind: 'city', type: 'town', name: 'Parma', within: 'Cuyahoga County, Ohio', visited: true }, has), {
    name: 'Parma',
    kindKey: 'map.fog.type.town',
    within: 'Cuyahoga County, Ohio',
    visitedKey: 'map.fog.place.visited',
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
