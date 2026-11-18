import { test } from 'node:test';
import assert from 'node:assert/strict';
// Plain .mjs so tsc (which has no Node types here) leaves it alone; Node strips the types
// from the imported .ts module itself. Run with `npm run test:unit`. The rules run from
// testdata/client-rules/edit-route-*.json in clientRules.test.mjs.
import { applyEdit, dragPreview, foldEdit, moveOp } from '../src/ui/editRouteOps.ts';

test('replaying an edit leaves the recorded points as they were', () => {
  const points = [[13, 52, 1000], [13, 52.0001, 2000], [13, 52.0002, 3000]];
  const copy = structuredClone(points);
  applyEdit(points, foldEdit({ drop: [1000] }, [moveOp(2000, 13.5, 52.5)]));
  assert.deepEqual(points, copy);
});

test('dragPreview is the dragged point and the line to its neighbours', () => {
  const pts = [[0, 0, 10], [1, 1, 11], [2, 2, 12]];
  assert.deepEqual(dragPreview(pts, 1, 5, 6), [[0, 0], [5, 6], [2, 2]]);
  assert.deepEqual(dragPreview(pts, 0, 5, 6), [[5, 6], [1, 1]], 'the first point has one neighbour');
  assert.deepEqual(dragPreview(pts, 2, 5, 6), [[1, 1], [5, 6]], 'the last point has one neighbour');
  assert.deepEqual(dragPreview(pts, -1, 5, 6), [], 'a point no longer visible');
  assert.deepEqual(dragPreview(pts, 3, 5, 6), [], 'past the end');
});
