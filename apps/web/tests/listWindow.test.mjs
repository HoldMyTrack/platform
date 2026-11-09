import { test } from 'node:test';
import assert from 'node:assert/strict';
import { listWindow, OVERSCAN, scrollTopFor } from '../src/ui/listWindow.ts';

test('the rows in view, and a few either side', () => {
  // 1,000 rows of 50 px, a 500 px view scrolled to row 100.
  assert.deepEqual(listWindow(1000, 50, 5000, 500), { start: 100 - OVERSCAN, end: 110 + OVERSCAN });
});

test("the window stops at the list's ends", () => {
  assert.deepEqual(listWindow(1000, 50, 0, 500), { start: 0, end: 10 + OVERSCAN });
  assert.deepEqual(listWindow(1000, 50, 49_500, 500), { start: 990 - OVERSCAN, end: 1000 });
  assert.deepEqual(listWindow(5, 50, 0, 500), { start: 0, end: 5 });
  assert.deepEqual(listWindow(0, 50, 0, 500), { start: 0, end: 0 });
});

test('before a row is measured, every row renders', () => {
  assert.deepEqual(listWindow(30, 0, 0, 500), { start: 0, end: 30 });
});

test('a row is scrolled to the middle of the view, within the list', () => {
  assert.equal(scrollTopFor(100, 1000, 50, 500), 100 * 50 - 225);
  assert.equal(scrollTopFor(0, 1000, 50, 500), 0);
  assert.equal(scrollTopFor(999, 1000, 50, 500), 1000 * 50 - 500);
  assert.equal(scrollTopFor(2, 3, 50, 500), 0);
});
