import { test } from 'node:test';
import assert from 'node:assert/strict';
import { settledMove } from '../src/map/areaLoad.ts';

test('a settled move reads the new view from zoom 4', () => {
  assert.equal(settledMove(4, false), 'load');
  assert.equal(settledMove(12, false), 'load');
});

test('below zoom 4 a move leaves the list, the Edit window open or not', () => {
  assert.equal(settledMove(3.99, false), 'none');
  assert.equal(settledMove(3.99, true), 'none');
});

test('with the Edit window open a move waits for it to close', () => {
  assert.equal(settledMove(4, true), 'later');
  assert.equal(settledMove(12, true), 'later');
});
