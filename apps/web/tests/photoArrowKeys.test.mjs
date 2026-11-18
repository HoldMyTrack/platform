import { test } from 'node:test';
import assert from 'node:assert/strict';
import { arrowKeyAction, PAN_STEP, pannable } from '../src/ui/photoZoom.ts';

const none = { x: false, y: false };

test('while the photo fits, the side arrows step between photos', () => {
  assert.equal(arrowKeyAction('ArrowLeft', none), 'previous');
  assert.equal(arrowKeyAction('ArrowRight', none), 'next');
  assert.equal(arrowKeyAction('ArrowUp', none), null);
});

test('an arrow pans along an axis the zoomed photo can move along, bringing that side into view', () => {
  assert.deepEqual(arrowKeyAction('ArrowLeft', { x: true, y: true }), { pan: { dx: PAN_STEP, dy: 0 } });
  assert.deepEqual(arrowKeyAction('ArrowDown', { x: true, y: true }), { pan: { dx: 0, dy: -PAN_STEP } });
});

test('a zoomed photo still narrower than the stage steps on the side arrows', () => {
  assert.equal(arrowKeyAction('ArrowRight', { x: false, y: true }), 'next');
  assert.deepEqual(arrowKeyAction('ArrowUp', { x: false, y: true }), { pan: { dx: 0, dy: PAN_STEP } });
});

test('a photo can move along an axis where, zoomed, it is larger than the stage', () => {
  const stage = { width: 1000, height: 800 };
  const portrait = { width: 400, height: 800 };
  assert.deepEqual(pannable({ scale: 1.5, x: 0, y: 0 }, portrait, stage), { x: false, y: true });
  assert.deepEqual(pannable({ scale: 3, x: 0, y: 0 }, portrait, stage), { x: true, y: true });
  assert.deepEqual(pannable({ scale: 1, x: 0, y: 0 }, portrait, stage), { x: false, y: false });
});
