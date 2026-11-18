import { test } from 'node:test';
import assert from 'node:assert/strict';
import { retryDelay } from '../src/map/retryDelay.ts';

test('a poll that answers waits its base interval', () => {
  assert.equal(retryDelay(0, 2000, 60_000), 2000);
});

test('each failure in a row doubles the wait, up to the cap', () => {
  assert.deepEqual([1, 2, 3, 4, 5, 6].map((n) => retryDelay(n, 2000, 60_000)), [4000, 8000, 16_000, 32_000, 60_000, 60_000]);
});
