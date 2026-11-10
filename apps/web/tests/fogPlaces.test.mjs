// PROTOTYPE (FOG_REWORK.md "Borders and names"): the tooltip for the outline under the pointer in Fog.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { placeLabel } from '../src/map/fogPlaceLabel.ts';

test('an outline is named with its kind and whether it is explored', () => {
  assert.deepEqual(placeLabel({ kind: 'city', name: 'Parma', visited: true }), {
    name: 'Parma',
    kindKey: 'map.fog.place.city',
    visitedKey: 'map.fog.place.visited',
  });
  assert.equal(placeLabel({ kind: 'county', name: 'Coconino County', visited: false }).kindKey, 'map.fog.place.county');
  assert.equal(placeLabel({ kind: 'region', name: 'Ohio', visited: 'false' }).visitedKey, 'map.fog.place.unvisited');
});

test('the sea, an unknown kind or a missing name has no tooltip', () => {
  assert.equal(placeLabel({ kind: 'sea', visited: false }), null);
  assert.equal(placeLabel({ kind: 'township', name: 'X' }), null);
  assert.equal(placeLabel({ kind: 'city', name: '' }), null);
  assert.equal(placeLabel({}), null);
});
