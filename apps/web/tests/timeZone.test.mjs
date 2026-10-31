// Covers docs/SPEC.md FR-3.11 (an activity's own timezone); the rule runs from
// testdata/client-rules/activity-zone.json in clientRules.test.mjs.
import { test } from 'node:test';
import assert from 'node:assert/strict';
// Plain .mjs, like editTrackOps.test.mjs: Node strips the types from the imported .ts module itself.
import { activityTimeZone } from '../src/ui/timeZone.ts';
import { todayIn } from '../src/ui/dateMath.ts';

test('the zone formats in the activity\'s wall clock, and an unknown one in the browser\'s without throwing', () => {
  const at = new Date('2026-03-09T22:30:00Z');
  const tokyo = at.toLocaleString('en-GB', { timeZone: activityTimeZone('Asia/Tokyo', undefined), dateStyle: 'medium', timeStyle: 'short' });
  assert.equal(tokyo, '10 Mar 2026, 07:30');
  assert.doesNotThrow(() => at.toLocaleString('en-GB', { timeZone: activityTimeZone('Mars/Olympus_Mons', undefined) }));
});

test("today is the account's calendar day, read at the moment asked (FR-1.7)", () => {
  const lateEvening = new Date('2026-09-12T23:30:00Z');
  assert.equal(todayIn('Asia/Tokyo', lateEvening), '2026-09-13');
  assert.equal(todayIn('America/New_York', lateEvening), '2026-09-12');
  assert.equal(todayIn('UTC', new Date('2026-09-13T00:00:01Z')), '2026-09-13');
  assert.match(todayIn('Mars/Olympus_Mons', lateEvening), /^\d{4}-\d{2}-\d{2}$/);
});
