import { test } from 'node:test';
import assert from 'node:assert/strict';
import { importsInFlight, showsFirstRun } from '../src/ui/firstRun.ts';

test('the first-run panel shows only for a real account known to have no activities', () => {
  assert.equal(showsFirstRun(false, false), true);
  assert.equal(showsFirstRun(false, true), false);
  assert.equal(showsFirstRun(false, null), false, 'not before the first page of days lands');
  assert.equal(showsFirstRun(true, false), false, 'never in a demo');
});

test('the in-flight count is read from the Upload menu, anything unreadable as none', () => {
  assert.equal(importsInFlight('3'), 3);
  assert.equal(importsInFlight('0'), 0);
  assert.equal(importsInFlight(null), 0);
  assert.equal(importsInFlight(undefined), 0);
  assert.equal(importsInFlight(''), 0);
  assert.equal(importsInFlight('-1'), 0);
  assert.equal(importsInFlight('2.5'), 0);
  assert.equal(importsInFlight('x'), 0);
});