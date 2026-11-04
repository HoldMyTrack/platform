import { test } from 'node:test';
import assert from 'node:assert/strict';
import { satelliteOffered } from '../src/map/imageryOffered.ts';

test('Satellite is offered when the build configures imagery and the server has not paused it', () => {
  assert.equal(satelliteOffered(true, true), true);
  assert.equal(satelliteOffered(true, false), false);
});

test('until the server answers, or after a failed read, the build decides', () => {
  assert.equal(satelliteOffered(true, null), true);
  assert.equal(satelliteOffered(false, null), false);
});

test('a build without imagery never offers it, whatever the server says', () => {
  assert.equal(satelliteOffered(false, true), false);
});
