import { test } from 'node:test';
import assert from 'node:assert/strict';
import { statsCardKey, statsCardRequest } from '../src/map/exportStats.ts';

const size = { widthPx: 1920, heightPx: 1080 };

test('the card is asked for only with Show stats ticked and offered', () => {
  assert.equal(statsCardRequest(false, new Set(['a']), null, size, false), null);
  assert.equal(statsCardRequest(true, new Set(), null, size, false), null);
  assert.equal(statsCardRequest(true, new Set(['a']), 'story', size, false), null);
});

test('the request carries the image size and theme, its ids sorted', () => {
  assert.deepEqual(statsCardRequest(true, new Set(['b', 'a']), null, size, true), { activityIds: ['a', 'b'], width: 1920, height: 1080, theme: 'dark' });
  assert.equal(statsCardRequest(true, new Set(['a']), null, size, false).theme, 'light');
});

test('the same checked set, size and theme is the same key; any change is another', () => {
  const key = (checked, s = size, dark = false) => statsCardKey(statsCardRequest(true, new Set(checked), null, s, dark));
  assert.equal(key(['a', 'b']), key(['b', 'a']));
  assert.notEqual(key(['a']), key(['a', 'b']));
  assert.notEqual(key(['a']), key(['a'], { widthPx: 1080, heightPx: 1080 }));
  assert.notEqual(key(['a']), key(['a'], size, true));
  assert.equal(statsCardKey(null), '');
});
