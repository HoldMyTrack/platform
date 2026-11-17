import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mapLimited } from '../src/limited.ts';

const tick = () => new Promise((resolve) => setTimeout(resolve, 1));

test('results come back in order, never more than the limit at once', async () => {
  let running = 0;
  let peak = 0;
  const out = await mapLimited([5, 1, 4, 2, 3], 2, async (n) => {
    running++;
    peak = Math.max(peak, running);
    for (let i = 0; i < n; i++) await tick();
    running--;
    return n * 10;
  });
  assert.deepEqual(out, [50, 10, 40, 20, 30]);
  assert.equal(peak, 2);
});

test('a failure rejects the whole and starts no more', async () => {
  const started = [];
  await assert.rejects(
    mapLimited([1, 2, 3, 4], 1, async (n) => {
      started.push(n);
      if (n === 2) throw new Error('no');
      return n;
    }),
    /no/,
  );
  assert.deepEqual(started, [1, 2]);
});

test('nothing to do is an empty result', async () => {
  assert.deepEqual(await mapLimited([], 4, async () => 1), []);
});
