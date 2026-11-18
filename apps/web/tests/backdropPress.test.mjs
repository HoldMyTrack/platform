import { test } from 'node:test';
import assert from 'node:assert/strict';
import { onBackdrop } from '../src/ui/backdropPress.ts';

const box = { left: 100, right: 300, top: 50, bottom: 250 };

test('a press outside the box on the dialog element is on the backdrop', () => {
  assert.equal(onBackdrop(true, box, 50, 100), true);
  assert.equal(onBackdrop(true, box, 200, 260), true);
});

test("a press inside the box is the dialog's own padding", () => {
  assert.equal(onBackdrop(true, box, 200, 100), false);
  assert.equal(onBackdrop(true, box, 100, 50), false);
});

test('a press on anything inside the dialog is never the backdrop', () => {
  assert.equal(onBackdrop(false, box, 50, 100), false);
});
