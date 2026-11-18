import { test } from 'node:test';
import assert from 'node:assert/strict';
import { arrowKeyAction, PAN_STEP } from '../src/ui/photoZoom.ts';

test('while the photo fits, the side arrows step between photos', () => {
  assert.equal(arrowKeyAction('ArrowLeft', false), 'previous');
  assert.equal(arrowKeyAction('ArrowRight', false), 'next');
  assert.equal(arrowKeyAction('ArrowUp', false), null);
});

test('while zoomed, every arrow pans, bringing that side into view', () => {
  assert.deepEqual(arrowKeyAction('ArrowLeft', true), { pan: { dx: PAN_STEP, dy: 0 } });
  assert.deepEqual(arrowKeyAction('ArrowDown', true), { pan: { dx: 0, dy: -PAN_STEP } });
});
