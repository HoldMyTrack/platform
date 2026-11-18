import { test } from 'node:test';
import assert from 'node:assert/strict';
import { nextTab } from '../src/ui/tabKeys.ts';

test('the arrows move between tabs and wrap at the ends', () => {
  assert.equal(nextTab('ArrowRight', 0, 3), 1);
  assert.equal(nextTab('ArrowRight', 2, 3), 0);
  assert.equal(nextTab('ArrowLeft', 0, 3), 2);
});

test('Home and End go to the first and last tab', () => {
  assert.equal(nextTab('Home', 2, 3), 0);
  assert.equal(nextTab('End', 0, 3), 2);
});

test('any other key, or no tabs, moves nowhere', () => {
  assert.equal(nextTab('Enter', 1, 3), null);
  assert.equal(nextTab('ArrowRight', 0, 0), null);
});
