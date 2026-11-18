import { test } from 'node:test';
import assert from 'node:assert/strict';
import { overlayInPlace } from '../src/map/overlayOrder.ts';

test('an overlay right under the first label, in its own order, is in place', () => {
  assert.equal(overlayInPlace(['water', 'tracks', 'a', 'b', 'label'], ['a', 'b'], 'label'), true);
});

test('a group added under the label after it puts it out of place', () => {
  assert.equal(overlayInPlace(['water', 'a', 'b', 'bike-paths', 'label'], ['a', 'b'], 'label'), false);
  assert.equal(overlayInPlace(['b', 'a', 'label'], ['a', 'b'], 'label'), false);
  assert.equal(overlayInPlace(['a', 'label'], ['a', 'b'], 'label'), false);
});

test('a style with no labels asks nothing', () => {
  assert.equal(overlayInPlace(['a', 'b', 'tracks'], ['a', 'b'], undefined), true);
});
