import { test } from 'node:test';
import assert from 'node:assert/strict';
import { centredScrollTop, listWindow, OVERSCAN, UNMEASURED_ROWS } from '../src/ui/listWindow.ts';

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

test('before a row is measured, the first few render', () => {
  assert.deepEqual(listWindow(30, 0, 0, 500), { start: 0, end: 30 });
  assert.deepEqual(listWindow(1000, 0, 0, 500), { start: 0, end: UNMEASURED_ROWS });
});

test('centredScrollTop centres a row that starts below other content', () => {
  assert.equal(centredScrollTop(10, 120, 50, 500), 120 + 500 - 225);
  assert.equal(centredScrollTop(0, 120, 50, 500), 120 - 225, 'negative: the browser clamps it to the top');
});
