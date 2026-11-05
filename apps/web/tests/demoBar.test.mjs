import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DEMO_BAR_HIDE_MS, demoBarShown, readHiddenUntil } from '../src/ui/demoBar.ts';

test('the demo bar shows in a demo session until hidden, and again once the hiding runs out', () => {
  const now = 1_800_000_000_000;
  assert.equal(demoBarShown(true, null, now), true);
  assert.equal(demoBarShown(true, now + 1, now), false);
  assert.equal(demoBarShown(true, now + DEMO_BAR_HIDE_MS, now + DEMO_BAR_HIDE_MS - 1), false);
  assert.equal(demoBarShown(true, now, now), true);
  assert.equal(demoBarShown(false, null, now), false, 'never in a real account');
});

test('a stored hidden-until time is read, anything unreadable as none', () => {
  assert.equal(readHiddenUntil('1800000000000'), 1_800_000_000_000);
  assert.equal(readHiddenUntil(null), null);
  assert.equal(readHiddenUntil(''), null);
  assert.equal(readHiddenUntil('soon'), null);
  assert.equal(readHiddenUntil('-5'), null);
});