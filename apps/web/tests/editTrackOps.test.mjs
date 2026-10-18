import { test } from 'node:test';
import assert from 'node:assert/strict';
// Plain .mjs so tsc (which has no Node types here) leaves it alone; Node strips the types
// from the imported .ts module itself. Run with `npm run test:unit`. The rules run from
// testdata/client-rules/edit-track-*.json in clientRules.test.mjs.
import { applyEdit, foldEdit, moveOp } from '../src/ui/editTrackOps.ts';

test('replaying an edit leaves the recorded points as they were', () => {
  const points = [[13, 52, 1000], [13, 52.0001, 2000], [13, 52.0002, 3000]];
  const copy = structuredClone(points);
  applyEdit(points, foldEdit({ drop: [1000] }, [moveOp(2000, 13.5, 52.5)]));
  assert.deepEqual(points, copy);
});
