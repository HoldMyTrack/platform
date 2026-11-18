import { test } from 'node:test';
import assert from 'node:assert/strict';
import { folderClick, isFolded } from '../src/ui/tripFold.ts';

test('a click on the open Trip folds its list, and the next unfolds it, without opening anything', () => {
  assert.deepEqual(folderClick(null, 'a', 'a'), { foldedId: 'a', open: false });
  assert.deepEqual(folderClick('a', 'a', 'a'), { foldedId: null, open: false });
});

test('a click on another Trip opens it unfolded', () => {
  assert.deepEqual(folderClick('a', 'a', 'b'), { foldedId: null, open: true });
  assert.deepEqual(folderClick(null, null, 'b'), { foldedId: null, open: true });
});

test('only a fold on the open Trip hides its list', () => {
  assert.equal(isFolded('a', 'a'), true);
  // Opened again some other way (the URL, deleting the open one) after a fold on another.
  assert.equal(isFolded('a', 'b'), false);
  assert.equal(isFolded(null, 'a'), false);
  assert.equal(isFolded('a', null), false);
});
