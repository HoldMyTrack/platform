import { test } from 'node:test';
import assert from 'node:assert/strict';
import { highlightedCircle, openingLocation, pickAction } from '../src/ui/privateLocationPick.ts';

const closed = { open: false, dirty: false, busy: false };

test('with no editor open, a pick applies', () => {
  assert.equal(pickAction(closed, 'a'), 'apply');
});

test('a Save in flight ignores every pick', () => {
  assert.equal(pickAction({ open: true, id: 'a', dirty: true, busy: true }, 'b'), 'ignore');
  assert.equal(pickAction({ ...closed, busy: true }, 'a'), 'ignore');
});

test('picking the location already in the editor keeps it, unsaved changes and all', () => {
  assert.equal(pickAction({ open: true, id: 'a', dirty: true, busy: false }, 'a'), 'keep');
});

test('picking another location asks only when the editor has unsaved changes', () => {
  assert.equal(pickAction({ open: true, id: 'a', dirty: true, busy: false }, 'b'), 'confirm');
  assert.equal(pickAction({ open: true, id: 'a', dirty: false, busy: false }, 'b'), 'apply');
  // A new circle not saved yet has no id and is always dirty.
  assert.equal(pickAction({ open: true, dirty: true, busy: false }, 'b'), 'confirm');
});

test('the editor draft is highlighted over the focused location', () => {
  const locations = [{ id: 'a' }, { id: 'b' }];
  const draft = { id: 'a', moved: true };
  assert.equal(highlightedCircle(locations, draft, 'b'), draft);
  assert.equal(highlightedCircle(locations, null, 'b'), locations[1]);
  assert.equal(highlightedCircle(locations, null, null), null);
  // A focused location deleted since is no longer drawn.
  assert.equal(highlightedCircle(locations, null, 'gone'), null);
  assert.equal(highlightedCircle(null, null, 'a'), null);
});

test('the Privacy tab opens on the location added last', () => {
  assert.deepEqual(openingLocation([{ id: 'a' }, { id: 'b' }]), { id: 'b' });
  assert.equal(openingLocation([]), null);
});
