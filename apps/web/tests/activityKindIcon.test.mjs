import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Bike, Car, Footprints, Route } from 'lucide-react';
import { kindIcon, typeIcon } from '../src/ui/activityKindIcon.ts';
import { rememberTypeKinds } from '../src/ui/activityTypes.ts';

test('each kind has its own icon', () => {
  assert.equal(kindIcon('foot'), Footprints);
  assert.equal(kindIcon('wheels'), Bike);
  assert.equal(kindIcon('motor'), Car);
  assert.equal(kindIcon('other'), Route);
  const all = ['foot', 'wheels', 'motor', 'solowheel', 'e_scooter', 'other'].map(kindIcon);
  assert.equal(new Set(all).size, all.length);
});

test("a type takes the icon of the kind the server gave it, else the other kind's", () => {
  rememberTypeKinds([['gravel_ride', 'wheels']]);
  assert.equal(typeIcon('gravel_ride'), Bike);
  assert.equal(typeIcon('never_described_here'), Route);
});
